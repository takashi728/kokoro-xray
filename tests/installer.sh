#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

repo="${TMP}/repo"
install_dir="${TMP}/install"
state="${TMP}/state"
mkdir -p "$repo"
git init -q "$repo"
cp -a "${ROOT}/." "$repo/"
rm -rf "${repo}/.git"
git init -q "$repo"
git -C "$repo" add .
git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
    commit -qm "fixture"
commit="$(git -C "$repo" rev-parse HEAD)"

stub_bin="${TMP}/bin"
install -d "$stub_bin"
cat >"${stub_bin}/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${stub_bin}/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
chmod +x "${stub_bin}/apt-get" "${stub_bin}/dpkg-query"
cat >"${stub_bin}/kokoro-xray" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${stub_bin}/kokoro-xray"
printf 'ID=debian\n' >"${TMP}/os-release"

run_installer() {
    local expected="$1"
    bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / --bind "$TMP" "$TMP" \
        --dev /dev --proc /proc --tmpfs /run \
        --ro-bind "${TMP}/os-release" /usr/lib/os-release \
        --bind "$stub_bin" /usr/local/bin --chdir "$repo" \
        /usr/bin/env HOME="$state" TMPDIR="$TMP" KOKORO_INSTALL_DIR="$install_dir" \
        KOKORO_REPO_COMMIT="$expected" PATH="${stub_bin}:${PATH}" \
        bash "${repo}/install.sh" --commit "$expected" </dev/null
}

# The local install path accepts only a clean checkout at the reviewed commit.
run_installer "$commit" >/dev/null
[[ -f "${install_dir}/kokoro-xray.sh" ]]
[[ "$(cat "${state}/.kokoro-xray/installed-commit")" == "$commit" ]]
[[ "$(cat "${install_dir}/.kokoro-install-commit")" == "$commit" ]]
[[ "$(stat -c '%a' "${install_dir}/install.sh")" == "755" ]]
[[ -f "${install_dir}/tools/xhttp-round-robin.sh" ]]
HOME="$state" bash "${stub_bin}/kokoro-xray" link --help >"${TMP}/link-help"
grep -Fq 'link --json round-robin DIRECT_IP UP DOWN' "${TMP}/link-help"

printf 'sentinel\n' >"${install_dir}/sentinel"
before="$(sha256sum "${install_dir}/sentinel" | awk '{print $1}')"
if run_installer 0000000000000000000000000000000000000000 >/dev/null 2>"${TMP}/mismatch.err"; then
    echo "mismatched installer commit unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'does not match reviewed commit' "${TMP}/mismatch.err"
[[ -f "${install_dir}/sentinel" ]]
[[ "$(sha256sum "${install_dir}/sentinel" | awk '{print $1}')" == "$before" ]]
[[ "$(cat "${state}/.kokoro-xray/installed-commit")" == "$commit" ]]

# A matching commit is insufficient if tracked files in the local checkout have
# uncommitted changes.
printf '\n# dirty\n' >>"${repo}/kokoro-xray.sh"
if run_installer "$commit" >/dev/null 2>&1; then
    echo "dirty local checkout unexpectedly succeeded" >&2
    exit 1
fi
git -C "$repo" checkout -- kokoro-xray.sh

# A clean local reinstall from the live install tree must use the pinned remote
# copy instead of recursively copying the tree onto itself.
if KOKORO_INSTALL_SOURCE=local bwrap --unshare-user --uid 0 --gid 0 \
    --ro-bind / / --bind "$TMP" "$TMP" --dev /dev --proc /proc --tmpfs /run \
    --ro-bind "${TMP}/os-release" /usr/lib/os-release \
    --bind "$stub_bin" /usr/local/bin --chdir "$install_dir" \
    /usr/bin/env HOME="$state" TMPDIR="$TMP" KOKORO_INSTALL_DIR="$install_dir" \
    KOKORO_REPO_COMMIT="$commit" PATH="${stub_bin}:${PATH}" \
    bash "${install_dir}/install.sh" --clean-install --commit "$commit" </dev/null \
    >/dev/null 2>&1; then
    echo "clean local reinstall unexpectedly succeeded" >&2
    exit 1
fi

# A plain local tree with neither .git nor a recorded revision is not trusted.
plain="${TMP}/plain"
mkdir -p "$plain"
cp -a "${ROOT}/." "$plain/"
rm -rf "${plain}/.git" "${plain}/.kokoro-install-commit"
if bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / --bind "$TMP" "$TMP" \
    --dev /dev --proc /proc --tmpfs /run \
    --ro-bind "${TMP}/os-release" /usr/lib/os-release \
    --bind "$stub_bin" /usr/local/bin --chdir "$plain" \
    /usr/bin/env HOME="$state" TMPDIR="$TMP" KOKORO_INSTALL_DIR="${TMP}/plain-install" \
    KOKORO_REPO_COMMIT="$commit" PATH="${stub_bin}:${PATH}" \
    bash "${plain}/install.sh" --commit "$commit" </dev/null >/dev/null 2>&1; then
    echo "unversioned local tree unexpectedly succeeded" >&2
    exit 1
fi
[[ ! -e "${TMP}/plain-install" ]]

# Remote mode must reject a mismatched commit before swapping the install.
if bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / --bind "$TMP" "$TMP" \
    --dev /dev --proc /proc --tmpfs /run \
    --ro-bind "${TMP}/os-release" /usr/lib/os-release \
    --bind "$stub_bin" /usr/local/bin --chdir "$repo" \
    /usr/bin/env HOME="$state" TMPDIR="$TMP" KOKORO_INSTALL_DIR="$install_dir" \
    KOKORO_REPO_URL="file://${repo}" \
    KOKORO_REPO_COMMIT=0000000000000000000000000000000000000000 \
    PATH="${stub_bin}:${PATH}" \
    bash "${repo}/install.sh" --remote \
    --commit 0000000000000000000000000000000000000000 </dev/null >/dev/null 2>&1; then
    echo "mismatched remote installer unexpectedly succeeded" >&2
    exit 1
fi
[[ -f "${install_dir}/sentinel" ]]

# Remote mode fetches the requested object directly and still succeeds when it
# matches the reviewed SHA.
bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / --bind "$TMP" "$TMP" \
    --dev /dev --proc /proc --tmpfs /run \
    --ro-bind "${TMP}/os-release" /usr/lib/os-release \
    --bind "$stub_bin" /usr/local/bin --chdir "$TMP" \
    /usr/bin/env HOME="$state" TMPDIR="$TMP" KOKORO_INSTALL_DIR="$install_dir" \
    KOKORO_REPO_URL="file://${repo}" KOKORO_REPO_COMMIT="$commit" \
    PATH="${stub_bin}:${PATH}" \
    bash "${repo}/install.sh" --remote --commit "$commit" </dev/null >/dev/null 2>&1
[[ "$(cat "${state}/.kokoro-xray/installed-commit")" == "$commit" ]]
[[ "$(git -C "$install_dir" rev-parse HEAD)" == "$commit" ]]

echo "installer-test OK"
