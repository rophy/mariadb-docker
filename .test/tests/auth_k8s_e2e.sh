#!/bin/bash
# End-to-end tests for mariadb-auth-k8s plugin on Kind
# Requires: kind, kubectl
# Sourced by run.sh — do not execute directly
# shellcheck disable=SC2154

AUTH_K8S_KIND_CLUSTER="mariadb-docker-test"
AUTH_K8S_KUBE_CTX="kind-${AUTH_K8S_KIND_CLUSTER}"
AUTH_K8S_NS="mariadb-auth-test"

_auth_k8s_e2e_check_deps() {
	command -v kind >/dev/null 2>&1 || die "kind is required but not installed"
	command -v kubectl >/dev/null 2>&1 || die "kubectl is required but not installed"
}

_auth_k8s_e2e_setup() {
	if ! kind get clusters 2>/dev/null | grep -q "^${AUTH_K8S_KIND_CLUSTER}$"; then
		echo "Creating Kind cluster ${AUTH_K8S_KIND_CLUSTER}..."
		kind create cluster --name "$AUTH_K8S_KIND_CLUSTER" --wait 60s
	fi

	echo "Loading image into Kind..."
	kind load docker-image "$image" --name "$AUTH_K8S_KIND_CLUSTER"

	echo "Applying K8s manifests..."
	sed "s|MARIADB_IMAGE_PLACEHOLDER|${image}|g" "$dir/k8s/auth-k8s.yaml" \
		| kubectl --context "$AUTH_K8S_KUBE_CTX" apply -f -

	echo "Waiting for MariaDB pod..."
	kubectl --context "$AUTH_K8S_KUBE_CTX" -n "$AUTH_K8S_NS" \
		wait --for=condition=Ready pod/mariadb --timeout=90s

	echo "Waiting for client pods..."
	kubectl --context "$AUTH_K8S_KUBE_CTX" -n "$AUTH_K8S_NS" \
		wait --for=condition=Ready pod/client-user1 --timeout=60s
	kubectl --context "$AUTH_K8S_KUBE_CTX" -n "$AUTH_K8S_NS" \
		wait --for=condition=Ready pod/client-user2 --timeout=60s

	echo "Waiting for MariaDB to accept connections..."
	local i
	for i in {30..0}; do
		if kubectl --context "$AUTH_K8S_KUBE_CTX" -n "$AUTH_K8S_NS" \
			exec client-user1 -- mariadb -h mariadb --protocol tcp -e 'SELECT 1' 2>/dev/null; then
			break
		fi
		sleep 1
	done
	[ "$i" -gt 0 ] || die "MariaDB did not become ready in Kind"
}

_auth_k8s_e2e_teardown() {
	echo "Cleaning up Kind cluster ${AUTH_K8S_KIND_CLUSTER}..."
	kind delete cluster --name "$AUTH_K8S_KIND_CLUSTER" 2>/dev/null || true
}

_auth_k8s_ka() {
	kubectl --context "$AUTH_K8S_KUBE_CTX" -n "$AUTH_K8S_NS" "$@"
}

test_auth_k8s_e2e() {
	echo -e "Test: auth_k8s end-to-end on Kind cluster\n"

	_auth_k8s_e2e_check_deps
	_auth_k8s_e2e_setup

	local failures=0

	# --- Plugin is loaded ---
	echo "  Checking plugin is loaded..."
	local plugin_status
	plugin_status=$(_auth_k8s_ka exec mariadb -- \
		mariadb -u root --skip-ssl --skip-column-names -Be \
		"SELECT plugin_status FROM information_schema.plugins WHERE plugin_name='auth_k8s'")
	if [ "$plugin_status" != "ACTIVE" ]; then
		echo "  FAIL: plugin not active (got: $plugin_status)"
		(( failures++ ))
	fi

	# --- user1 authenticates with valid SA token ---
	echo "  Checking user1 auth with valid token..."
	if ! _auth_k8s_ka exec client-user1 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" -e "SELECT 1"' \
		2>/dev/null; then
		echo "  FAIL: user1 auth failed with valid token"
		(( failures++ ))
	fi

	# --- user1 SELECT USER() returns correct identity ---
	echo "  Checking user1 identity..."
	local user_result
	user_result=$(_auth_k8s_ka exec client-user1 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" --skip-column-names -Be "SELECT USER()"' \
		2>/dev/null)
	if [[ "$user_result" != *"mariadb-auth-test/user1"* ]]; then
		echo "  FAIL: expected user identity mariadb-auth-test/user1, got: $user_result"
		(( failures++ ))
	fi

	# --- user2 can access testdb ---
	echo "  Checking user2 auth and testdb access..."
	if ! _auth_k8s_ka exec client-user2 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "mariadb-auth-test/user2" -p"$SA_TOKEN" -D testdb -e "SELECT 1"' \
		2>/dev/null; then
		echo "  FAIL: user2 auth or testdb access failed"
		(( failures++ ))
	fi

	# --- user2 cannot access mysql database ---
	echo "  Checking user2 denied access to mysql db..."
	if _auth_k8s_ka exec client-user2 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "mariadb-auth-test/user2" -p"$SA_TOKEN" -D mysql -e "SELECT 1"' \
		2>/dev/null; then
		echo "  FAIL: user2 should not have access to mysql database"
		(( failures++ ))
	fi

	# --- invalid token is rejected ---
	echo "  Checking invalid token is rejected..."
	if _auth_k8s_ka exec client-user1 -- bash -c \
		'mariadb -h mariadb -u "mariadb-auth-test/user1" -p"invalid-token" -e "SELECT 1"' \
		2>/dev/null; then
		echo "  FAIL: invalid token should be rejected"
		(( failures++ ))
	fi

	# --- wrong username is rejected (user1 token with user2 name) ---
	echo "  Checking wrong username is rejected..."
	if _auth_k8s_ka exec client-user1 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "mariadb-auth-test/user2" -p"$SA_TOKEN" -e "SELECT 1"' \
		2>/dev/null; then
		echo "  FAIL: user1 token with user2 name should be rejected"
		(( failures++ ))
	fi

	# --- wrong namespace is rejected ---
	echo "  Checking wrong namespace is rejected..."
	if _auth_k8s_ka exec client-user1 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "wrong-ns/user1" -p"$SA_TOKEN" -e "SELECT 1"' \
		2>/dev/null; then
		echo "  FAIL: wrong namespace should be rejected"
		(( failures++ ))
	fi

	# --- multiple sequential connections succeed ---
	echo "  Checking multiple sequential connections..."
	if ! _auth_k8s_ka exec client-user1 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" -e "SELECT 1" && mariadb -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" -e "SELECT 2" && mariadb -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" -e "SELECT 3"' \
		2>/dev/null; then
		echo "  FAIL: multiple sequential connections failed"
		(( failures++ ))
	fi

	# --- cleartext auth works (MDEV-38431 compat) ---
	echo "  Checking cleartext auth (MDEV-38431)..."
	if ! _auth_k8s_ka exec client-user1 -- bash -c \
		'SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && mariadb -h mariadb -u "mariadb-auth-test/user1" -p"$SA_TOKEN" --default-auth=mysql_clear_password -e "SELECT 1"' \
		2>/dev/null; then
		echo "  FAIL: cleartext auth failed"
		(( failures++ ))
	fi

	_auth_k8s_e2e_teardown

	if [ "$failures" -gt 0 ]; then
		die "auth_k8s e2e: $failures sub-test(s) failed"
	fi
}
