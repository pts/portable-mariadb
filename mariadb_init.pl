#! /usr/bin/perl -w
#
# mariadb_init.pl: Simple init script for mariadb-compact
# by pts@fazekas.hu at Sat Nov  5 20:22:42 CET 2011
#

use integer;
use strict;
use Errno qw(ESRCH);
use Cwd qw();
use IO::Socket::UNIX qw(SOL_SOCKET SO_PEERCRED);

sub WNOHANG() {1}

die "Usage: $0 { start | stop | restart }\n" if @ARGV != 1 or
    ($ARGV[0] ne 'start' and $ARGV[0] ne 'stop' and $ARGV[0] ne 'restart');
my $cmd = $ARGV[0];

my $cwd = Cwd::abs_path($0);  # Also resolves symlinks.
$cwd =~ s@/+[^/]+\Z(?!\n)@@ if defined $cwd;
die "$0: cwd: $!\n" if !defined($cwd) or substr($cwd, 0, 1) ne "/";
die "$0: not an executable: $cwd/bin/mysqld" if !-x "$cwd/bin/mysqld";
die "$0: missing: $cwd/share/mysql/english/errmsg.sys" if
    !-f "$cwd/share/mysql/english/errmsg.sys";

# Connect to Unix domain socket (mysqld.sock), get the PID of the server.
sub get_server_unix_pid() {
  my $sock = new IO::Socket::UNIX("$cwd/mysqld.sock");
  return undef if !$sock;
  my $res = $sock->getsockopt(SOL_SOCKET, SO_PEERCRED);
  die "$0: peercred: $!\n" if
      !$res or length($res) != length(pack('III', 0, 0, 0));
  my ($pid, $uid, $gid) = unpack('III', $res);
  close $sock;
  $pid
}

sub stop_low($) {
  my ($server_pid) = @_;
  if (!kill('QUIT', $server_pid)) {
    if ($! != ESRCH) {
      my $errnum = $! + 0;
      print "error($errnum)\n";
      exit 2;
    }
    my $server_pid2 = get_server_unix_pid();
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
    my $server_pid3 = get_server_unix_pid();
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

  my $server_pid = get_server_unix_pid();
  if ($server_pid and $server_pid > 0) {
    if (!$is_already_ok) {
      print "already-running\n";
      exit 1;
    }
    stop_low($server_pid);
  }

  unlink "$cwd/mysqld.sock";  # TODO(pts): Get rid of the race.
  unlink "$cwd/mysqld.pid";  # TODO(pts): Get rid of the race.
  die "$0: could not remove: $cwd/mysqld.sock" if -e "$cwd/mysqld.sock";

  my $logfn = "$cwd/mysqld.new.log";
  my $logf;
  die "$0: open for append: $logfn: $!\n" if !open $logf, '>>', $logfn;
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
        './bin/mysqld', '--skip-networking', '--datadir=./data',
        '--pid-file=./mysqld.pid',
        "--socket=$cwd/mysqld.sock",  # ./ would put it to --datadir
        '--language=./share/mysql/english', '--console');
    exit(127);
  }
  my($sec, $min, $hour, $mday, $mon, $year) = gmtime();
  my $logid = sprintf("%04d-%02d-%02d.%02d:%02d:%02d.%05d", 1900 + $year, $mon + 1, $mday, $hour, $min, $sec, $pid);
  # TODO(pts): Also include the date in the jobname.
  die "$0: rename $cwd/mysqld.new.log to $cwd/mysqld.$logid.log: $!\n" if
      !rename("$cwd/mysqld.new.log", "$cwd/mysqld.$logid.log");

  my $rlogf;
  die "$0: open $cwd/mysqld.$logid.log: $!\n" if
      !open($rlogf, '<', "$cwd/mysqld.$logid.log");

  while (1) {
    my $gotpid = waitpid($pid, WNOHANG);
    if (!$gotpid or $gotpid != $pid) {
      # Doesn't work with `seek', it caches too much after the first read.
      die "$0: seek: $!\n" if !sysseek $rlogf, 0, 0;
      my $rlog;
      die "$0: read: #!\n" if !defined(sysread($rlogf, $rlog, 4096));
      last if 0 <= index($rlog, ' [Note] ./bin/mysqld: ready for connections.');
      select undef, undef, undef, 0.1;
      next
    }
    printf "exited-too-early(0x%x)\n", $?;
    exit 2;
  }

  my $cwdq = $cwd;
  if ($cwdq =~ y@-_./+a-zA-Z0-9@@c) {
    $cwdq =~ s@'@'\\''@g;
    $cwdq = "'$cwdq'";
  }
  print "done.\nConnect with: mysql --socket=$cwdq/mysqld.sock --user=root --database=test\n";
}

sub stop() {
  print "Stopping MariaDB in $cwd: ";

  my $server_pid = get_server_unix_pid();
  if (!($server_pid and $server_pid > 0)) {
    print "not-running\n";
    exit 1;
  }

  stop_low($server_pid);

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
