#!/bin/bash
# Tests for the mariadb-auth-k8s plugin
# Sourced by run.sh — do not execute directly
# shellcheck disable=SC2154

test_auth_k8s_plugin_load() {
	echo -e "Test: auth_k8s plugin can be loaded and registers system variables\n"

	runandwait \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}" \
		--plugin-load-add=auth_k8s

	plugins=$(mariadbclient -u root --skip-column-names -Be \
		"SELECT plugin_name, plugin_status FROM information_schema.plugins WHERE plugin_name = 'auth_k8s'")
	[[ "$plugins" == *"ACTIVE"* ]] || die "auth_k8s plugin not active: $plugins"

	timeout_val=$(mariadbclient -u root --skip-column-names -Be \
		"SELECT variable_value FROM information_schema.global_variables WHERE variable_name = 'auth_k8s_timeout'")
	[ "$timeout_val" = "10" ] || die "expected auth_k8s_timeout=10, got: $timeout_val"

	if docker exec "$cname" $mariadb -u root -e "SET GLOBAL auth_k8s_timeout = 30" 2>/dev/null; then
		die "auth_k8s_timeout should be read-only but SET succeeded"
	fi

	killoff
}

test_auth_k8s_user_create() {
	echo -e "Test: users can be created with auth_k8s authentication\n"

	runandwait \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}" \
		--plugin-load-add=auth_k8s

	mariadbclient -u root -e "CREATE USER 'testns/testsa'@'%' IDENTIFIED VIA auth_k8s"
	mariadbclient -u root -e "GRANT SELECT ON *.* TO 'testns/testsa'@'%'"

	auth_plugin=$(mariadbclient -u root --skip-column-names -Be \
		"SELECT plugin FROM mysql.global_priv WHERE user = 'testns/testsa'" 2>/dev/null \
		|| mariadbclient -u root --skip-column-names -Be \
		"SELECT json_value(priv, '$.plugin') FROM mysql.global_priv WHERE user = 'testns/testsa'")
	[[ "$auth_plugin" == *"auth_k8s"* ]] || die "user auth plugin not auth_k8s: $auth_plugin"

	grants=$(mariadbclient -u root --skip-column-names -Be \
		"SHOW GRANTS FOR 'testns/testsa'@'%'")
	[[ "$grants" == *"SELECT"* ]] || die "user grants missing SELECT: $grants"

	killoff
}

test_auth_k8s_reject_no_k8s() {
	echo -e "Test: auth_k8s rejects login when no Kubernetes API is available\n"

	runandwait \
		-e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 \
		"${image}" \
		--plugin-load-add=auth_k8s

	mariadbclient -u root -e "CREATE USER 'fakens/fakesa'@'%' IDENTIFIED VIA auth_k8s"
	mariadbclient -u root -e "GRANT ALL ON *.* TO 'fakens/fakesa'@'%'"

	if docker exec -i "$cname" $mariadb \
		-u 'fakens/fakesa' \
		-pfaketoken \
		--default-auth=mysql_clear_password \
		-e 'SELECT 1' 2>&1; then
		die "auth_k8s should reject login without Kubernetes API"
	fi
	echo "expected auth rejection without Kubernetes API"

	mariadbclient -u root -e 'SELECT 1' || die "root should still work after failed auth_k8s attempt"

	killoff
}
