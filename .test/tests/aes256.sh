#!/bin/bash
# Tests for the lib_mysqludf_aes256 UDF plugin
# Sourced by run.sh — do not execute directly
# shellcheck disable=SC2154

test_aes256_udf_register() {
	echo -e "Test: lib_mysqludf_aes256 UDFs can be registered\n"

	runandwait \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}"

	mariadbclient -u root -e "CREATE FUNCTION lib_mysqludf_aes256_info RETURNS string SONAME 'lib_mysqludf_aes256.so'"
	mariadbclient -u root -e "CREATE FUNCTION aes256_encrypt RETURNS string SONAME 'lib_mysqludf_aes256.so'"
	mariadbclient -u root -e "CREATE FUNCTION aes256_decrypt RETURNS string SONAME 'lib_mysqludf_aes256.so'"

	info=$(mariadbclient -u root --skip-column-names -Be "SELECT lib_mysqludf_aes256_info()")
	[ -n "$info" ] || die "lib_mysqludf_aes256_info() returned empty"

	killoff
}

test_aes256_encrypt_decrypt() {
	echo -e "Test: aes256_encrypt/aes256_decrypt roundtrip\n"

	runandwait \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}"

	mariadbclient -u root -e "CREATE FUNCTION aes256_encrypt RETURNS string SONAME 'lib_mysqludf_aes256.so'"
	mariadbclient -u root -e "CREATE FUNCTION aes256_decrypt RETURNS string SONAME 'lib_mysqludf_aes256.so'"

	result=$(mariadbclient -u root --skip-column-names -Be \
		"SELECT aes256_decrypt(aes256_encrypt('hello world', 'mysecretkey'), 'mysecretkey')")
	[ "$result" = "hello world" ] || die "roundtrip failed, got: $result"

	result2=$(mariadbclient -u root --skip-column-names -Be \
		"SELECT aes256_decrypt(aes256_encrypt('', 'key'), 'key')")
	[ "$result2" = "" ] || die "empty string roundtrip failed, got: $result2"

	killoff
}

test_aes256_wrong_key() {
	echo -e "Test: aes256_decrypt with wrong key returns NULL\n"

	runandwait \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}"

	mariadbclient -u root -e "CREATE FUNCTION aes256_encrypt RETURNS string SONAME 'lib_mysqludf_aes256.so'"
	mariadbclient -u root -e "CREATE FUNCTION aes256_decrypt RETURNS string SONAME 'lib_mysqludf_aes256.so'"

	result=$(mariadbclient -u root --skip-column-names -Be \
		"SELECT IFNULL(aes256_decrypt(aes256_encrypt('secret', 'rightkey'), 'wrongkey'), 'NULL_RESULT')")
	[ "$result" != "secret" ] || die "wrong key should not decrypt correctly"

	killoff
}
