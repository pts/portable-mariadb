#! /bin/bash --
# by pts@fazekas.hu at 2010-08-09

set -ex

#TARGZ=mariadb-5.2.1-beta-Linux-i686.tar.gz
#TARGZ_URL=http://ftp.rediris.es/mirror/MariaDB/mariadb-5.2.1-beta/kvm-bintar-hardy-x86/${TARGZ}
TARGZ=mariadb-5.2.9-Linux-i686.tar.gz
TARGZ_URL=http://downloads.askmonty.org/f/mariadb-5.2.9/kvm-bintar-hardy-x86/mariadb-5.2.9-Linux-i686.tar.gz/from/http:/mirror.switch.ch/mirror/mariadb
MARIADB_INIT_PL="${0%/*}/mariadb_init.pl"
test -f "$MARIADB_INIT_PL"

if ! test -f /tmp/${TARGZ}; then
  wget -O /tmp/${TARGZ}.download ${TARGZ_URL}
  mv -f /tmp/${TARGZ}.download /tmp/${TARGZ}
fi
rm -rf /tmp/mariadb-preinst
mkdir -p /tmp/mariadb-preinst
cd /tmp/mariadb-preinst
tar xzvf /tmp/${TARGZ} ${TARGZ%.tar.*}/\
{bin/mysqld{,_safe},bin/my_print_defaults,scripts/mysql_install_db,\
share/mysql/english/errmsg.sys,share/fill_help_tables.sql,\
share/mysql_fix_privilege_tables.sql,share/mysql_system_tables.sql,\
share/mysql_system_tables_data.sql,share/mysql_test_data_timezone.sql}
cd ${TARGZ%.tar.*}
strip -s bin/mysqld
./scripts/mysql_install_db --basedir="$PWD" --force --datadir="$PWD"/data
rm -rf scripts
rm -f share/*.sql
cd ..
mv ${TARGZ%.tar.*} mariadb-compact
cp "$MARIADB_INIT_PL" mariadb-compact/mariadb_init.pl
chmod 755 mariadb-compact/mariadb_init.pl
tar cjvf /tmp/mariadb-compact.tbz2 mariadb-compact
#rm -f /tmp/${TARGZ}
rm -rf /tmp/mariadb-preinst
ls -l /tmp/mariadb-compact.tbz2 
