#! /bin/bash --
# by pts@fazekas.hu at 2010-08-09

set -ex

umask 022

#TARGZ=mariadb-5.2.1-beta-Linux-i686.tar.gz
#TARGZ_URL=http://ftp.rediris.es/mirror/MariaDB/mariadb-5.2.1-beta/kvm-bintar-hardy-x86/${TARGZ}
TARGZ=mariadb-5.2.9-Linux-i686.tar.gz
TARGZ_URL=http://downloads.askmonty.org/f/mariadb-5.2.9/kvm-bintar-hardy-x86/mariadb-5.2.9-Linux-i686.tar.gz/from/http:/mirror.switch.ch/mirror/mariadb
MARIADB_INIT_PL="${0%/*}/mariadb_init.pl"
MY_CNF="${0%/*}/my.cnf"
README_TXT="${0%/*}/README.txt"
test -f "$MARIADB_INIT_PL"

TMPDIR=.
TMPABSDIR=$(cd "$TMPDIR" && pwd)
test "$TMPABSDIR"

if ! test -f $TMPDIR/${TARGZ}; then
  wget -O $TMPDIR/${TARGZ}.download ${TARGZ_URL}
  mv -f $TMPDIR/${TARGZ}.download $TMPDIR/${TARGZ}
fi
rm -rf $TMPDIR/mariadb-preinst
mkdir -p $TMPDIR/mariadb-preinst
cp -f "$MARIADB_INIT_PL" "$TMPDIR"/mariadb-preinst/
if test -f "$MY_CNF"; then
  cp "$MY_CNF" "$TMPDIR"/mariadb-preinst/
else
  touch "$TMPDIR"/mariadb-preinst/my.cnf
fi
if test -f "$README_TXT"; then
  cp "$README_TXT" "$TMPDIR"/mariadb-preinst/
else
  touch "$TMPDIR"/mariadb-preinst/README.txt
fi
cd $TMPDIR/mariadb-preinst
tar xzvf $TMPABSDIR/${TARGZ} ${TARGZ%.tar.*}/\
{bin/mysqld,bin/my_print_defaults,scripts/mysql_install_db,\
share/mysql,share/fill_help_tables.sql,\
share/mysql_fix_privilege_tables.sql,share/mysql_system_tables.sql,\
share/mysql_system_tables_data.sql,share/mysql_test_data_timezone.sql}
cd ${TARGZ%.tar.*}
strip -s bin/mysqld
./scripts/mysql_install_db --basedir="$PWD" --force --datadir="$PWD"/data
# The default password is empty, but we change it to invalid so that login
# will not be possible until someone sets up a working password e.g. with
# SET password=PASSWORD('working').
echo "UPDATE mysql.user SET password='refused' WHERE user='root'" |
    bin/mysqld --bootstrap --datadir=./data --language=./share/mysql/english \
    --console --log-warnings=0 --loose-skip-innodb --loose-skip-ndbcluster \
    --loose-skip-pbxt --loose-skip-federated --loose-skip-aria \
    --loose-skip-maria --loose-skip-archive
rm -rf scripts
rm -f share/*.sql
rm -f data/aria_log*
mkdir log
cd ..  # Back to $TMPDIR/mariadb-preinst.
mv ${TARGZ%.tar.*} portable-mariadb
mv mariadb_init.pl my.cnf README.txt portable-mariadb/
chmod 755 portable-mariadb/mariadb_init.pl
tar cjvf ../portable-mariadb.tbz2 portable-mariadb
#rm -f $TMPDIR/${TARGZ}
cd "$TMPABSDIR"
rm -rf mariadb-preinst
ls -l "$TMPABSDIR"/portable-mariadb.tbz2 
