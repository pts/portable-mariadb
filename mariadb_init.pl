#! /usr/bin/perl -w
#
# mariadb_init.pl: Simple init script for mariadb-compact
# by pts@fazekas.hu at Sat Nov  5 20:22:42 CET 2011
#
# Please note that this init script is agnostic of the mysqld pidfile: it
# starts and stops mysqld without taking a look at the pidfile.
#
# Please note that this init script is not reentrant: it may behave strangely
# if multiple instances of it run at the same time.

use integer;
use strict;
use Errno qw(ESRCH);
use Cwd qw();
use IO::Socket::UNIX qw(SOL_SOCKET SO_PEERCRED);
use Sys::Hostname qw();

sub WNOHANG() {1}
sub F_WRLCK() {1}
sub F_GETLK() {5}
sub F_SETLK() {6}

die "Usage: $0 { start | stop | restart }\n" if @ARGV != 1 or
    ($ARGV[0] ne 'start' and $ARGV[0] ne 'stop' and $ARGV[0] ne 'restart');
my $cmd = $ARGV[0];

my $cwd = Cwd::abs_path($0);  # Also resolves symlinks.
$cwd =~ s@/+[^/]+\Z(?!\n)@@ if defined $cwd;
die "$0: cwd: $!\n" if !defined($cwd) or substr($cwd, 0, 1) ne "/";
die "$0: not an executable: $cwd/bin/mysqld" if !-x "$cwd/bin/mysqld";
die "$0: missing: $cwd/share/mysql/english/errmsg.sys" if
    !-f "$cwd/share/mysql/english/errmsg.sys";
my $cwdq = $cwd;
if ($cwdq =~ y@-_./+a-zA-Z0-9@@c) {
  $cwdq =~ s@'@'\\''@g;
  $cwdq = "'$cwdq'";
}

sub get_defaults() {
  my $output = readpipe(
      "exec bin/mysqld --defaults-file=$cwdq/my.cnf --print-defaults 2>&1");
  # Please note that mysqld returns $? == 0 here even on an error.
  return $output if $? or $output =~ m@^(Fatal Error|Error|Could not)@mi;
  $output =~ s@\A.* would have been started with the following arguments:\n@@;
  $output =~ s@\s+\Z(?!\n)@@;
  $output =~ s@\A\s*@ @;
  return "(multiline)$output" if $output =~ /\n/;
  return "(bad-prefix)$output" if $output !~ /\A --/;
  my $defaults = {};
  # Spaces in values etc. are not escaped, so we just split on ` --'.
  for my $entry (split(/ --/, $output)) {
    if (0 != length($entry)) {
      # my.cnf names anf mysqld command-line flags are case sensitive.
      if ($entry =~ /\A([a-zA-Z][-\w]*)\Z(?!\n)/) {
        $defaults->{$1} = undef;  # e.g. $defaults{'skip-networking'} = undef;
      } elsif ($entry =~ /\A([a-zA-Z][-\w]*)=(.*)\Z(?!\n)/s) {
        $defaults->{$1} = $2;
      } else {
        return "(bad-entry) $entry";
      }
    }
  }

  if (exists $defaults->{datadir} and not
      (!defined $defaults->{datadir} or 0 == length($defaults->{datadir}))) {
    return "my.cnf must not have datadir specified for Portable MariaDB.";
  }

  if (exists $defaults->{console} and not
      (!defined $defaults->{console} or 0 == length($defaults->{console}))) {
    return "my.cnf must not have console specified for Portable MariaDB.";
  }

  if (defined $defaults->{socket} and length($defaults->{socket}) > 0) {
    if (substr($defaults->{socket}, 0, 1) ne '/') {
      # mysqld would treat a relative --socket= relative to --datadir= even with
      # --socket=./BLAH, so we make it relative to $cwd here.
      $defaults->{socket} =~ s@\A([.]/+)+@@;
      substr($defaults->{socket}, 0, 0, "$cwd/");
    }
    $defaults->{'.socket'} = $defaults->{socket};
  } else {
    $defaults->{'.socket'} = "$cwd/mysqld.sock";
  }

  if (defined $defaults->{'log-error'} and
      length($defaults->{'log-error'}) > 0) {
    if (substr($defaults->{'log-error'}, 0, 1) ne '/') {
      # mysqld would treat a relative --log-error= relative to --datadir= even with
      # --log-error=./BLAH, so we make it relative to $cwd here.
      $defaults->{'log-error'} =~ s@\A([.]/+)+@@;
      substr($defaults->{'log-error'}, 0, 0, "$cwd/");
    }
  }
  $defaults->{'.log-error'} = $defaults->{'log-error'};
  
  if (defined $defaults->{'pid-file'} &&
      length($defaults->{'pid-file'}) > 0) {
    if (substr($defaults->{'pid-file'}, 0, 1) ne '/') {
      # mysqld would treat a relative --pid-file= relative to --datadir=, so
      # we make it relative to $cwd here.
      $defaults->{'pid-file'} =~ s@\A([.]/+)+@@;
      substr($defaults->{'pid-file'}, 0, 0, "$cwd/");
    }
    $defaults->{'.pid-file'} = $defaults->{'pid-file'};
  } else {
    # mysqld insists on creating a pidfile, so we supply a reasonable default.
    $defaults->{'.pid-file'} = "$cwd/mysqld.pid";
  }

  if (defined $defaults->{'character-sets-dir'} &&
      length($defaults->{'character-sets-dir'}) > 0) {
    if (substr($defaults->{'character-sets-dir'}, 0, 1) ne '/') {
      # mysqld would treat a relative --character-sets-dir= relative to
      # --datadir=, so we make it relative to $cwd here.
      $defaults->{'character-sets-dir'} =~ s@\A([.]/+)+@@;
      substr($defaults->{'character-sets-dir'}, 0, 0, "$cwd/");
    }
    $defaults->{'.character-sets-dir'} = $defaults->{'character-sets-dir'};
  } else {
    $defaults->{'.character-sets-dir'} = "./share/mysql/charsets";
  }

  if (defined $defaults->{language}) {
    if ($defaults->{language} !~ m@/@) {
      # Default directory would be:
      # "/usr/local/mysql/share/mysql/$defaults->{language}/errmsg.sys".
      $defaults->{language} = "./share/mysql/$defaults->{language}";
    } elsif (substr($defaults->{language}, 0, 1) ne '/') {
      # Default directory if starting with `./' is $cwd.
      $defaults->{language} =~ s@\A([.]/+)+@@;
      substr($defaults->{language}, 0, 0, "./");
    }
    $defaults->{'.language'} = $defaults->{language};
  } else {
    $defaults->{'.language'} = './share/mysql/english';
  }

  $defaults
}

# Find the Unix domain socket where the mysqld runnin in $cwd is listening,
# and set $defaults->{'.stop_socket'} to the filename if found.
#
# This function is useful for finding the mysqld to stop, even if we don't
# know the --socket= flag it was started with.
sub find_stop_socket($) {
  my ($defaults) = @_;
  return if exists $defaults->{'.stop_socket'};
  my %pids;
  my @files = ("data/aria_log_control", "data/ibdata1", "data/iblogfile0",
               "data/ib_logfile1", "data/tc.log",
               "data/mysql/host.MYD");  # Usually not locked.
  for my $fn (@files) {
    my $f;
    if (open $f, '+<', "$cwd/$fn") {
      # This is Linux-specific.
      my $req = pack("Sx30", F_WRLCK);
      my $res = $req;
      # Use the same kind of locking my_lock() in mysqld does.
      if (fcntl($f, F_GETLK, $res) and
          substr($res, 0, 2) eq substr($req, 0, 2)) {
        my $pid = length($res) >= 16 && substr($res, 12, 4) ne "\0\0\0\0" ?
                      unpack('I', substr($res, 12, 4)) : # 32-bit Linux.
                      unpack('I', substr($res, 24, 4));  # 64-bit Linux.
        $pids{$pid} = 1 if $pid;
      }
      close $f;
    }
  }
  return if !%pids;
  my @our_pids;
  my @absfiles = map { "$cwd/$_" } @files;
  my %socket_numbers;
  for my $pid (sort { $a <=> $b } keys %pids) {
    my $df;
    my $is_found = 0;
    my %my_socket_numbers;
    if (opendir($df, "/proc/$pid/fd")) {
      while (my $entryf = readdir($df)) {
        next if $entryf =~ y@0-9@@c;
        my $target = readlink("/proc/$pid/fd/$entryf");
        if (!defined $target) {
        } elsif (grep { $_ eq $target } @absfiles) {
          $is_found = 1;
        } elsif ($target =~ m@\Asocket:\[(\d+)\]\Z(?!\n)@) {
          $my_socket_numbers{$1} = 1;
        }
      }
      die if !closedir $df;
      @socket_numbers{keys %my_socket_numbers} = (1)x keys %my_socket_numbers
          if $is_found;
    }
  }
  return if !%socket_numbers;
  my %sockets;
  if (open my $uf, '<', '/proc/net/unix') {
    while (my $line = <$uf>) {
      chomp $line;
      my @items = split(/\s+/, $line, 8);
      $sockets{$items[7]} = 1 if exists $socket_numbers{$items[6]};
    }
    die if !close $uf;
  }
  return if keys(%sockets) != 1;
  my $socket = [keys%sockets]->[0];
  return if !-S $socket;
  $defaults->{'.stop_socket'} = $socket;
  return  # undef.
}

# Connect to Unix domain socket (mysqld.sock), get the PID of the server.
sub get_server_unix_pid($;$) {
  my ($defaults, $is_stop) = @_;
  # TODO(pts): Does this respect the Timeout=>?
  my $peer = $defaults->{'.socket'};
  $peer= $defaults->{'.stop_socket'} if $is_stop and defined
      $defaults->{'.stop_socket'};
  my $sock = new IO::Socket::UNIX(Peer=>$peer, Timeout=>3);
  return undef if !$sock;
  my $res = $sock->getsockopt(SOL_SOCKET, SO_PEERCRED);
  die "$0: peercred: $!\n" if
      !$res or length($res) != length(pack('III', 0, 0, 0));
  my ($pid, $uid, $gid) = unpack('III', $res);
  close $sock;
  $pid
}

sub stop_low($$) {
  my ($server_pid, $defaults) = @_;
  if (!kill('QUIT', $server_pid)) {
    if ($! != ESRCH) {
      my $errnum = $! + 0;
      print "error($errnum)\n";
      exit 2;
    }
    my $server_pid2 = get_server_unix_pid($defaults, 1);
    if (!($server_pid2 and $server_pid2 > 0)) {  # Killed by someone else.
      print "done.\n";
      return;
    }
    if (!kill('QUIT', $server_pid)) {
      my $errnum = $! + 0;
      print "error($errnum)\n";
      exit 2;
    } else {
      print "still-listening";
      exit 3;
    }
  }

  my $is_accepting = 1;
  for (my $i = 0; $i < 50; ++$i) {  # 5 seconds to stop accepting connections.
    my $server_pid3 = get_server_unix_pid($defaults, 1);
    if (!($server_pid3 and $server_pid3 > 0)) {
      $is_accepting = 0;
      last
    }
    select undef, undef, undef, 0.1;
  }
  if ($is_accepting) {
    print "still-accepting\n";
    exit 4;
  }
  my $is_running = 1;
  for (my $i = 0; $i < 200; ++$i)  {  # 20 seconds for exiting.
    if (!-e "/proc/$server_pid") {
      $is_running = 0;
      last
    }
    select undef, undef, undef, 0.1;
  }
  if ($is_running) {
    print "still-running\n";
    exit 5;
  }
}

sub start($) {
  my ($is_already_ok) = @_;
  if ($is_already_ok) {
    print "Restarting MariaDB in $cwd: ";
  } else {
    print "Starting MariaDB in $cwd: ";
  }

  my $defaults = get_defaults();
  if ('HASH' ne ref $defaults) {
    chomp $defaults;
    chomp $defaults;
    print "defaults-query-error\n$defaults\n";
    exit 9;
  }
  
  find_stop_socket($defaults);
  my $server_pid = get_server_unix_pid($defaults, 1);
  if ($server_pid and $server_pid > 0) {
    if (!$is_already_ok) {
      print "already-running\n";
      exit 1;
    }
    stop_low($server_pid, $defaults);
  }

  unlink $defaults->{'.socket'};  # TODO(pts): Get rid of the race.
  unlink "$cwd/mysqld.pid";  # TODO(pts): Get rid of the race.
  die "$0: could not remove: $defaults->{'.socket'}" if
      -e "$defaults->{'.socket'}";

  my $req_logfn = (defined $defaults->{'.log-error'} and
                   length($defaults->{'.log-error'}) > 0) ?
                  $defaults->{'.log-error'} : undef;

  my $logfn = defined $req_logfn ? $req_logfn : "$cwd/mysqld.new.log";
  my $logf;
  die "$0: open for append: $logfn: $!\n" if !open $logf, '>>', $logfn;
  my $logsize0 = sysseek($logf, 0, 2);  # EOF.
  die "$0: could not get log size: $!\n" if !defined $logsize0;
  my $pid = fork();
  die "$0: fork: $!\n" if !defined $pid;
  if (!$pid) {  # Child;
    die "child: open-stdin: $!\n" if !open STDIN, '<', '/dev/null';
    die "child: open-stdout: $!\n" if !open STDOUT, '>&', $logf;
    die "child: open-stderr: $!\n" if !open STDERR, '>&', $logf;
    die "child: chdir $cwd: $!\n"if !chdir $cwd;
    # TODO(pts): Close other filehandles.
    die "child: setpgrp: $!\n" if !setpgrp(0, 0);
    die "child: exec: $!\n" if !exec(
        './bin/mysqld',
        '--defaults-file=./my.cnf',  # Must be the 1st argument.
        # Values specified below override values specified in my.cnf .
        '--datadir=./data',
        "--socket=$defaults->{'.socket'}",
        "--language=$defaults->{'.language'}",
        "--pid-file=$defaults->{'.pid-file'}",
        "--character-sets-dir=$defaults->{'.character-sets-dir'}",
        '--console');  # Overrides and clear the MySQL log_error variable.
    exit(127);
  }

  close $logf;
  my $read_logfn = $logfn;
  if (!defined $req_logfn) {
    my ($sec, $min, $hour, $mday, $mon, $year) = gmtime();
    my $logid = sprintf('%04d-%02d-%02d.%02d:%02d:%02d.%05d', 1900 + $year,
                        $mon + 1, $mday, $hour, $min, $sec, $pid);
    $read_logfn = "cwd/mysqld.$logid.log";
    die "$0: rename $logfn to $read_logfn: $!\n" if
        !rename($logfn, $read_logfn);
  }
  my $rlogf;
  die "$0: open $read_logfn: $!\n" if
      !open($rlogf, '<', $read_logfn);

  my $retries = 400;  # Wait 40 seconds. (mysqld waits 30 seconds internally.)
  while (1) {
    my $gotpid = waitpid($pid, WNOHANG);
    # Doesn't work with `seek', it caches too much after the first read.
    die "$0: seek: $!\n" if !sysseek $rlogf, $logsize0, 0;
    my $rlog;
    die "$0: read: #!\n" if !defined(sysread($rlogf, $rlog, 32768));
    if (!$gotpid or $gotpid != $pid) {
      # We don't match for the `ready for connections' string, because it's
      # language-dependent.
      #
      #   English: [Note] ./bin/mysqld: ready for connections.
      #   German: [Note] ./bin/mysqld: bereit f\u00FCr Verbindungen.
      #
      # Even the subsequent line is language-dependent, but most languages have
      # either socket or Socket, so we match on that:
      #
      #   English: Version: '5.2.9-MariaDB'  socket: '/home/pts/mariadb-compact/foo.sock'  port: 3377  (MariaDB - http://mariadb.com/)
      #   German: Version: '5.2.9-MariaDB'  Socket: '/home/pts/mariadb-compact/foo.sock'  Port: 3377  (MariaDB - http://mariadb.com/)
      if ($rlog =~ /^Version: '[^'\\]+'  [sS]ocket: '([^'\\']+)'  /m) {
        if ($1 ne $defaults->{'.socket'}) {
          print "socket-mismatch\n";
          exit 6;
        }
        last;
      }
      if (--$retries < 0) {
        print "startup-timeout\n";
        exit 5;
      }
      select undef, undef, undef, 0.1;
      next
    }
    my $errmsg = "";
    while ($rlog =~ m@ \[Error\] (.*)@ig) {
      $errmsg .= "error: $1\n" if $1 ne 'Aborting';
    }
    printf "exited-too-early(0x%x)\n%s", $?, $errmsg;
    exit 2;
  }

  # This is mostly to verify that the Unix domain socket connection works.
  my $pid2 = get_server_unix_pid($defaults, 0);
  if (!defined $pid2) {
    my $errnum = $! + 0;
    print "error-unix-connect($errnum)\n";
    exit 3;
  }
  if ($pid != $pid2) {
    print "pid-mismatch($pid,$pid2)\n";
    exit 4;
  }

  my $sockq = $defaults->{'.socket'};
  if ($sockq =~ y@-_./+a-zA-Z0-9@@c) {
    $sockq =~ s@'@'\\''@g;
    $sockq = "'$sockq'";
  }
  my $conntcplocal = "";
  my $conntcp = "";
  my $connauth = " --user=root --database=test";
  if (!exists $defaults->{'skip-networking'}) {
    my $host;
    # `mysql --port=3306' is the default.
    my $portspec = defined $defaults->{port} && $defaults->{port} != 3306 ?
        " --port=" . ($defaults->{port} + 0) : "";
    my $localhost = '127.0.0.1';
    if (!defined $defaults->{'bind-address'} or
        length($defaults->{'bind-address'}) == 0) {
      $host = $localhost;
      undef $localhost;
    } elsif ($defaults->{'bind-address'} eq '0.0.0.0' or
             $defaults->{'bind-address'} =~ /\A0+\Z(?!\n)/) {
      $host = Sys::Hostname::hostname();
      if (index($host, '.') < 0) {
        my @res = gethostbyname($host);
        if (@res) {
          my @hosts = $res[0];
          push @hosts, split(/\s+/, $res[1]) if @res > 1;
          @hosts = grep { $_ ne 'localhost' and $_ ne 'localhost.localdomain' }
              @hosts;
          $host = $hosts[0] if @hosts;
        }
      }
    } else {
      $host = $defaults->{'bind-address'};
      undef $localhost;
    }
    $conntcp = "Connect with: mysql --host=$host$portspec$connauth\n";
    $conntcplocal = "Connect with: mysql --host=$localhost$portspec$connauth\n" if
        defined $localhost;
  }
  print "done (PID $pid).\n",
        "Connect with: mysql --socket=$sockq$connauth\n",
        $conntcplocal, $conntcp;
}

sub stop() {
  print "Stopping MariaDB in $cwd: ";

  my $defaults = get_defaults();
  if ('HASH' ne ref $defaults) {
    chomp $defaults;
    chomp $defaults;
    print "defaults-query-error\n$defaults\n";
    exit 9;
  }

  find_stop_socket($defaults);
  my $server_pid = get_server_unix_pid($defaults, 1);
  if (!($server_pid and $server_pid > 0)) {
    print "not-running\n";
    exit 1;
  }

  stop_low($server_pid, $defaults);

  # This is not strictly necessary, usually MariaDB cleans up after itself.
  unlink "$cwd/mysqld.pid";  # TODO(pts): Get rid of the race.

  print "done.\n";
}

$| = 1;
if ($cmd eq 'start') {
  start(0);
} elsif ($cmd eq 'stop') {
  stop();
} elsif ($cmd eq 'restart') {
  start(1);
}
