#!/usr/bin/bash
# policy-lib.sh -- build-time helpers for Auros policy modes.
#
# Sourced by apply-policy (and by build/20-policy.sh through it). Not executable on its own.
# Every function here is idempotent and every function here is loud.
#
# Installed to /usr/share/auros/policy/lib/policy-lib.sh so a recipe's own build layer can call
# apply-policy, which sources it from there.

# ── state paths (all under /usr, so nothing a runtime user can forge) ────────────────────────────
AUROS_STATE_DIR=${AUROS_STATE_DIR:-/usr/lib/auros}
AUROS_POLICY_STATE="$AUROS_STATE_DIR/policy"
AUROS_MODE_STAMP="$AUROS_STATE_DIR/policy-mode"
# NOT named AUROS_MANIFEST: build/00-common.sh exports AUROS_MANIFEST as the in-image build-step
# record (/usr/lib/auros/build-steps.tsv). Sharing that name would make auros_uninstall_previous
# delete every path listed in ANOTHER layer's manifest on the next mode switch.
AUROS_POLICY_MANIFEST="$AUROS_POLICY_STATE/installed.manifest"
AUROS_MASKED_UNITS="$AUROS_POLICY_STATE/masked.units"
AUROS_REPORT="$AUROS_POLICY_STATE/applied.json"
AUROS_KDEGLOBALS=${AUROS_KDEGLOBALS:-/etc/xdg/kdeglobals}

# The three kdeglobals groups this directory OWNS. Everything else in that file belongs to somebody
# else -- the Windows-familiarity layer owns [KDE] (SingleClick and friends), the theme layer owns
# the colour groups -- and is preserved byte-for-byte across every apply and every switch.
AUROS_KDEGLOBALS_GROUPS='KDE Action Restrictions|KDE Control Module Restrictions|KDE URL Restrictions'
AUROS_KDE_SENTINEL_BEGIN='# >>> auros-policy: KDE Kiosk restrictions (managed by apply-policy, do not edit)'
AUROS_KDE_SENTINEL_END='# <<< auros-policy'

# ── logging ──────────────────────────────────────────────────────────────────────────────────────
# Same shape as build/00-common.sh's logging, because this output is streamed verbatim by the
# website's build console (spec section 7) and two formats in one stream reads as two products.
# Defined here rather than sourced from 00-common.sh because apply-policy also runs from a CUSTOMER
# RECIPE's layer, where /tmp/auros-build has already been deleted by 90-cleanup.sh.
log()  { printf 'auros[policy] %s\n' "$*"; }
warn() { printf 'auros[policy]  ! %s\n' "$*" >&2; }
die()  { printf 'auros[policy]  x %s\n' "$*" >&2; exit 1; }

# ── package manager detection ────────────────────────────────────────────────────────────────────
# Aurora is an ostree container. Depending on the day and the upstream, removing a package from it is
# either a normal dnf transaction against a writable rootfs or an rpm-ostree override. Both appear in
# ublue's own build scripts. We detect rather than assume, try in order, and VERIFY with rpm -q
# afterwards -- because the one thing that must never happen is a removal that reports success and
# leaves the package installed.
auros_pkgmgr() {
    if command -v dnf5 >/dev/null 2>&1; then echo dnf5
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    else echo none
    fi
}

auros_pkg_installed() { rpm -q --quiet "$1"; }

# Measured, not estimated. %{SIZE} is the installed size rpm actually recorded for the package.
auros_pkg_size() { rpm -q --qf '%{SIZE}' "$1" 2>/dev/null || echo 0; }

auros_read_list() {
    # strip comments and blank lines from a .list file
    [ -r "$1" ] || return 0
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# ── the removal trap, handled explicitly ─────────────────────────────────────────────────────────
#
# Three separate mechanisms fight package removal on a Fedora/ostree image, and all three fail
# QUIETLY, which is the part that matters:
#
#   1. protected_packages   dnf refuses to remove anything named in /etc/dnf/protected.d/*.conf or in
#                           the protected_packages config option. The refusal is an error, so this
#                           one at least shouts -- but only if you were watching the right line.
#   2. weak dependencies    Recommends: pulls a removed package straight back in on the NEXT
#                           transaction in the same build. A later `dnf install` in the recipe layer
#                           silently reinstates the desktop you just deleted.
#   3. comps group state    The group stays marked installed. A later `dnf group upgrade` reinstates
#                           its packages. Nothing errors; the image is simply wrong.
#
# auros_disable_weak_deps and auros_remove_packages below deal with 1 and 2. auros_unmark_groups
# deals with 3, and reports honestly when it cannot.

auros_disable_weak_deps() {
    # Turn Recommends off for the whole build, not just for our own transactions, because the
    # transaction that undoes our removal is the RECIPE's install step, which we do not control.
    # Overridable ONLY so that policy/tests/policy-lib.test.sh can drive this function against a
    # fixture and prove it goes red when the key lands in the wrong INI section. Nothing in the
    # build sets it; the default is the real file.
    local conf=${AUROS_DNF_CONF:-/etc/dnf/dnf.conf}
    local marker='# >>> auros-policy'
    [ -f "$conf" ] || { warn "$conf not found; weak deps not disabled globally"; return 0; }
    if grep -qF "$marker" "$conf"; then
        log "weak dependencies already disabled globally in $conf"
        auros_verify_weak_deps "$conf"
        return 0
    fi

    # SHARED FILE, and INI SECTIONS ARE POSITIONAL -- which is why this inserts rather than appends.
    #
    # This used to `cat >>` the block onto the END of dnf.conf. dnf.conf is an INI file: a key
    # belongs to whatever section header precedes it. If any repo section or a [main]-unrelated
    # section follows [main] -- and nothing stops the hardening layer, a package drop-in or a future
    # Fedora default from adding one -- then install_weak_deps=False lands in THAT section and is
    # silently ignored. A later `dnf install` in the recipe layer then pulls Recommends back in and
    # reinstates the desktop we deleted. That is exactly the silent no-op this file's own header
    # (mechanism 2, "fail QUIETLY, which is the part that matters") warns about, committed by the
    # handler for it.
    #
    # So: insert immediately under the literal `[main]` header, and if there is no [main] at all,
    # create one at the top of the file. Then CHECK, the way auros_unmark_groups does -- "try, then
    # check, then say so out loud" rather than "do it and believe it".
    local tmp="${conf}.auros-new"
    if grep -qE '^[[:space:]]*\[main\][[:space:]]*$' "$conf"; then
        awk '
            BEGIN { done = 0 }
            {
                print
                if (!done && $0 ~ /^[[:space:]]*\[main\][[:space:]]*$/) {
                    print "# >>> auros-policy"
                    print "# install_weak_deps=False for the whole build. Recommends: is the mechanism that silently"
                    print "# drags a removed package back in on the next transaction -- including transactions in a"
                    print "# customer recipe'"'"'s own layer, which is why this is set globally rather than passed"
                    print "# per-command. It is inserted directly under [main] because an INI key belongs to the"
                    print "# section above it: appended at the end of the file it would land in whatever section"
                    print "# happened to be last and be ignored without a word. Check S3 is what catches it."
                    print "install_weak_deps=False"
                    print "# <<< auros-policy"
                    done = 1
                }
            }
        ' "$conf" > "$tmp"
    else
        warn "$conf has no [main] section; creating one at the top rather than appending a key with no section"
        {
            printf '[main]\n'
            printf '# >>> auros-policy\n'
            printf '# See auros_disable_weak_deps in policy-lib.sh. This [main] header was created by us\n'
            printf '# because the file had none, and a key with no section above it belongs to nothing.\n'
            printf 'install_weak_deps=False\n'
            printf '# <<< auros-policy\n'
            cat "$conf"
        } > "$tmp"
    fi
    cat "$tmp" > "$conf"
    rm -f "$tmp"
    log "disabled weak dependencies globally in $conf (inserted under [main], not appended)"
    auros_verify_weak_deps "$conf"
}

# Ask dnf what it actually resolved, rather than trusting that the edit landed where we meant it to.
# dnf5 answers with `--dump-main-config`; dnf4 with `dnf config-manager --dump`. If neither verb is
# available we say so instead of reporting a silent success -- an honest "not verified" in the build
# log is worth more than a `|| true`.
auros_verify_weak_deps() {
    local conf="$1" dnf out=""
    dnf="$(auros_pkgmgr)"
    [ "$dnf" = none ] && { warn "install_weak_deps is NOT VERIFIED in $conf: no dnf on this image to ask. If Recommends are still on, a later dnf install in the recipe layer can reinstate a package we removed; check S3 asserts the removal set from outside and is what would catch it."; return 0; }
    if out="$("$dnf" --dump-main-config 2>/dev/null)" && [ -n "$out" ]; then
        :
    elif out="$("$dnf" config-manager --dump 2>/dev/null)" && [ -n "$out" ]; then
        :
    else
        warn "neither '$dnf --dump-main-config' nor '$dnf config-manager --dump' produced output; install_weak_deps is NOT VERIFIED on this image. If Recommends are still on, a later dnf install in the recipe layer can reinstate a package we removed, and check S3 is what will catch it."
        return 0
    fi
    if grep -qiE '^[[:space:]]*install_weak_deps[[:space:]]*=[[:space:]]*(0|false|no)[[:space:]]*$' <<<"$out"; then
        log "verified: $dnf resolves install_weak_deps to False"
    else
        warn "MISMATCH: we wrote install_weak_deps=False into $conf but $dnf resolves it to '$(printf '%s' "$out" | grep -iE '^[[:space:]]*install_weak_deps' | head -1 | tr -d '[:space:]')'. Recommends are still on for this build, so a removed package can come back on the next transaction. Check S3 asserts the removal set from outside and will go red if it does."
    fi
}

# auros_remove_packages <remove.list> <keep.list>
# Appends measured per-package rows to $AUROS_REMOVED_TSV (name<TAB>bytes<TAB>mechanism).
auros_remove_packages() {
    local remove_list="$1" keep_list="$2"
    local dnf; dnf="$(auros_pkgmgr)"
    local -a want=() present=() missing=()
    local p

    while IFS= read -r p; do want+=("$p"); done < <(auros_read_list "$remove_list")
    [ "${#want[@]}" -gt 0 ] || { log "removal list is empty; nothing to do"; return 0; }

    for p in "${want[@]}"; do
        if auros_pkg_installed "$p"; then present+=("$p"); else missing+=("$p"); fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        # Not an error. Upstream renames and splits packages; the post-condition that actually
        # matters is absent-binaries.list, checked after this returns.
        log "not installed, skipped (${#missing[@]}): ${missing[*]}"
    fi
    if [ "${#present[@]}" -eq 0 ]; then
        log "nothing installed from the removal list"
        return 0
    fi

    # Measure BEFORE removing. Afterwards the information is gone, and "we removed 214 packages" is a
    # claim we put in front of customers -- it has to come from a measurement.
    local bytes total=0
    for p in "${present[@]}"; do
        bytes="$(auros_pkg_size "$p")"
        total=$(( total + bytes ))
        printf '%s\t%s\t%s\n' "$p" "$bytes" "pending" >> "${AUROS_REMOVED_TSV:?}"
    done
    log "removing ${#present[@]} packages, ${total} bytes installed size (measured): ${present[*]}"

    # ---- mechanism 1: protected_packages ----------------------------------------------------------
    # Neutralised two ways, because the config option and the drop-in directory are separate
    # mechanisms and different dnf versions honour different ones. Restored by trap on the way out,
    # so a failure mid-transaction does not leave the image's protections switched off.
    local protdir=/etc/dnf/protected.d protoff=/etc/dnf/protected.d.auros-off
    local restored=0
    _auros_restore_protected() {
        [ "$restored" = 1 ] && return 0
        [ -d "$protoff" ] && { rm -rf "$protdir"; mv "$protoff" "$protdir"; log "restored $protdir"; }
        restored=1
    }
    if [ -d "$protdir" ]; then
        rm -rf "$protoff"
        mv "$protdir" "$protoff"
        log "temporarily moved $protdir aside (protected_packages)"
        trap _auros_restore_protected EXIT
    fi

    local mechanism=""
    local rc=0
    if [ "$dnf" != none ]; then
        log "attempt 1: $dnf remove"
        if "$dnf" -y remove \
                --setopt=protected_packages= \
                --setopt=install_weak_deps=False \
                --setopt=clean_requirements_on_remove=True \
                "${present[@]}"; then
            mechanism="$dnf"
        else
            rc=$?
            warn "$dnf remove exited $rc; falling back to rpm-ostree override remove"
        fi
    fi
    if [ -z "$mechanism" ] && command -v rpm-ostree >/dev/null 2>&1; then
        log "attempt 2: rpm-ostree override remove"
        if rpm-ostree override remove "${present[@]}"; then
            mechanism="rpm-ostree"
        else
            warn "rpm-ostree override remove also failed"
        fi
    fi

    _auros_restore_protected
    trap - EXIT

    # DELIBERATELY NOT IN THE LADDER: `rpm -e --nodeps`.
    # It would make almost any removal "succeed" and leave the rpmdb with unsatisfiable Requires, so
    # the customer recipe's own install layer fails later, on a different day, for a reason nobody
    # can trace back to here. We would rather fail this build than ship an image whose package
    # database we broke to make a check go green.

    # ---- verify, per package, by the only thing that is not an opinion -----------------------------
    local -a survivors=()
    for p in "${present[@]}"; do
        if auros_pkg_installed "$p"; then
            survivors+=("$p")
            sed -i "s|^${p}\t\([0-9]*\)\tpending$|${p}\t\1\tSURVIVED|" "${AUROS_REMOVED_TSV}"
        else
            sed -i "s|^${p}\t\([0-9]*\)\tpending$|${p}\t\1\t${mechanism:-unknown}|" "${AUROS_REMOVED_TSV}"
        fi
    done
    if [ "${#survivors[@]}" -gt 0 ]; then
        warn "these packages survived removal: ${survivors[*]}"
        warn "that is not automatically fatal -- absent-binaries.list is the post-condition -- but it is"
        warn "the shape of the failure D12 warns about, and it is recorded in $AUROS_REPORT"
    fi

    # ---- the guard that actually protects the product ---------------------------------------------
    # A dependency cascade that takes systemd, bootc, NetworkManager or the update path with it
    # produces a machine we can never patch again: the abandoned laptop we sell against. Check S10
    # asserts this from outside. This check means the image cannot be BUILT in the first place.
    local -a casualties=()
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if ! auros_pkg_installed "$p"; then
            # Only a casualty if it was there before we started. A package that was never on the
            # image is not something we removed.
            if grep -qxF "$p" "${AUROS_KEEP_PRESENT_BEFORE:-/dev/null}" 2>/dev/null; then
                casualties+=("$p")
            fi
        fi
    done < <(auros_read_list "$keep_list")
    if [ "${#casualties[@]}" -gt 0 ]; then
        die "the removal transaction took protected packages with it: ${casualties[*]} -- refusing to build. See policy/kiosk/keep.list."
    fi
    log "protected set intact after removal"
}

# Record which keep.list packages were present before we touched anything, so the casualty check
# above can tell "we deleted it" from "it was never here".
auros_snapshot_keep() {
    local keep_list="$1" out="$2" p
    : > "$out"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        auros_pkg_installed "$p" && printf '%s\n' "$p" >> "$out"
    done < <(auros_read_list "$keep_list")
    log "protected set snapshot: $(wc -l < "$out") of the keep.list packages are installed on this image"
}

# ---- mechanism 3: comps group membership ---------------------------------------------------------
# A group that stays marked installed is a desktop waiting to be reinstated by the next
# `dnf group upgrade`. dnf4 and dnf5 disagree about the verb for unmarking, and neither is reliably
# present, so: try both, then CHECK, then say so out loud if the group is still marked. An honest
# warning in the build log is worth more than a silent `|| true`.
auros_unmark_groups() {
    local group_list="$1" g
    local dnf; dnf="$(auros_pkgmgr)"
    [ "$dnf" = none ] && { warn "no dnf available; comps groups not unmarked"; return 0; }
    [ -r "$group_list" ] || return 0

    while IFS= read -r g; do
        [ -n "$g" ] || continue
        if "$dnf" group mark remove "$g" >/dev/null 2>&1; then
            log "comps group '$g': unmarked via 'group mark remove'"
        elif "$dnf" -y group remove "$g" >/dev/null 2>&1; then
            log "comps group '$g': removed via 'group remove'"
        else
            log "comps group '$g': no unmark verb succeeded (it may simply not be installed)"
        fi
    done < <(auros_read_list "$group_list")

    # Now check, rather than believe.
    local still=""
    if still="$("$dnf" group list --installed 2>/dev/null || true)"; then
        while IFS= read -r g; do
            [ -n "$g" ] || continue
            if grep -qi -- "$g" <<<"$still"; then
                warn "comps group '$g' is STILL marked installed. A later 'dnf group upgrade' could reinstate its packages. Check S3 will catch that on the next build; recorded in $AUROS_REPORT."
                AUROS_GROUPS_STILL_MARKED="${AUROS_GROUPS_STILL_MARKED:+$AUROS_GROUPS_STILL_MARKED }$g"
            fi
        done < <(auros_read_list "$group_list")
    fi
}

# ── file installation with a manifest, so a mode switch really releases the previous mode ────────
auros_uninstall_previous() {
    local man="$1" p removed=0
    [ -r "$man" ] || { log "no previous policy manifest; nothing to release"; return 0; }
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$p" ] || [ -L "$p" ]; then rm -f "$p"; removed=$(( removed + 1 )); fi
    done < "$man"
    log "released $removed files installed by the previous policy mode"
    : > "$man"
}

auros_install_tree() {
    local src="$1" man="$2" rel
    [ -d "$src" ] || { log "no file tree at $src"; return 0; }
    ( cd "$src" && find . -mindepth 1 \( -type f -o -type l \) | sed 's|^\./||' ) | while IFS= read -r rel; do
        install -d -m 0755 "/$(dirname "$rel")"
        cp -a "$src/$rel" "/$rel"
        chown root:root "/$rel"
        printf '/%s\n' "$rel" >> "$man"
    done
    log "installed $(wc -l < "$man" | tr -d ' ') files from $src"
}

# ── kdeglobals: merge, never overwrite ───────────────────────────────────────────────────────────
# /etc/xdg/kdeglobals is a SHARED file. The Windows-familiarity layer (D4) owns [KDE] in it. We own
# exactly three groups. Clobbering the file would silently undo double-click-to-open, and the symptom
# would surface a week later as "the machines feel wrong", with nothing in any log.
auros_kdeglobals_strip() {
    local f="$1" tmp
    [ -f "$f" ] || return 0
    tmp="$(mktemp)"
    # 1. drop our sentinel block
    awk -v b="$AUROS_KDE_SENTINEL_BEGIN" -v e="$AUROS_KDE_SENTINEL_END" '
        $0 == b { inblk = 1; next }
        $0 == e { inblk = 0; next }
        !inblk  { print }
    ' "$f" > "$tmp"
    # 2. drop the groups we own even if the sentinels were lost to a hand-edit, so that re-applying
    #    a mode cannot leave two copies of a group in the file
    awk -v groups="$AUROS_KDEGLOBALS_GROUPS" '
        BEGIN { n = split(groups, g, "|"); for (i = 1; i <= n; i++) kill[g[i]] = 1; skip = 0 }
        /^[[:space:]]*\[/ {
            line = $0
            sub(/^[[:space:]]*\[/, "", line)
            idx = index(line, "]")
            name = (idx > 0) ? substr(line, 1, idx - 1) : line
            skip = (name in kill) ? 1 : 0
        }
        { if (!skip) print }
    ' "$tmp" > "$f"
    # 3. trim trailing blank lines. Without this, every rebuild of every image adds one more blank
    #    line to the file for the lifetime of the product. Harmless, and the kind of harmless that
    #    someone eventually has to explain.
    awk '{ l[NR] = $0 }
         END { last = NR
               while (last > 0 && l[last] ~ /^[[:space:]]*$/) last--
               for (i = 1; i <= last; i++) print l[i] }' "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

auros_kdeglobals_apply() {
    local frag_dir="$1" f found=0
    install -d -m 0755 "$(dirname "$AUROS_KDEGLOBALS")"
    [ -f "$AUROS_KDEGLOBALS" ] || : > "$AUROS_KDEGLOBALS"
    auros_kdeglobals_strip "$AUROS_KDEGLOBALS"
    [ -d "$frag_dir" ] || { log "no kdeglobals fragments for this mode"; return 0; }
    for f in "$frag_dir"/*.ini; do
        [ -e "$f" ] || continue
        if [ "$found" = 0 ]; then
            printf '\n%s\n' "$AUROS_KDE_SENTINEL_BEGIN" >> "$AUROS_KDEGLOBALS"
            found=1
        fi
        cat "$f" >> "$AUROS_KDEGLOBALS"
        printf '\n' >> "$AUROS_KDEGLOBALS"
    done
    [ "$found" = 1 ] && printf '%s\n' "$AUROS_KDE_SENTINEL_END" >> "$AUROS_KDEGLOBALS"
    chmod 0644 "$AUROS_KDEGLOBALS"
    log "merged $(ls -1 "$frag_dir"/*.ini 2>/dev/null | wc -l | tr -d ' ') kdeglobals fragments; groups owned: $AUROS_KDEGLOBALS_GROUPS"
}

# ── dconf ────────────────────────────────────────────────────────────────────────────────────────
auros_dconf_profile() {
    local prof=/etc/dconf/profile/user
    install -d -m 0755 /etc/dconf/profile
    if [ ! -f "$prof" ]; then
        printf 'user-db:user\nsystem-db:auros\n' > "$prof"
        log "created $prof with the auros system database"
    elif ! grep -qx 'system-db:auros' "$prof"; then
        # SHARED FILE: append rather than rewrite. Another layer may have its own system-db line.
        printf 'system-db:auros\n' >> "$prof"
        log "appended system-db:auros to the existing $prof"
    else
        log "$prof already references the auros system database"
    fi
}

auros_dconf_update() {
    if command -v dconf >/dev/null 2>&1; then
        # `|| die`, not `&& log`: as the last statement of this function, an AND-list whose left side
        # fails returns non-zero, and the caller runs under `set -e` -- so a dconf compile failure
        # would abort apply-policy silently, with no line saying which step died. An explicit die is
        # the same outcome with a message somebody can act on.
        dconf update || die "dconf update failed. The lock files are on the image but the binary database was not compiled, so the GTK lockdown is shipped and NOT in force -- which is the configured-but-not-effective state check B5 fails a mode for."
        log "compiled the dconf databases"
    else
        warn "dconf is not installed; the dconf locks are shipped but will not be compiled. GTK application lockdown is therefore NOT in force -- polkit and sudoers are unaffected."
    fi
}

auros_dconf_clear() {
    rm -rf /etc/dconf/db/auros.d /etc/dconf/db/auros
    log "cleared the auros dconf database"
}

# ── systemd, OFFLINE ─────────────────────────────────────────────────────────────────────────────
#
# There is no running systemd inside an image build, so `systemctl enable` and `systemctl mask` do
# not do what they look like they do. A policy layer whose masking silently no-ops is the exact
# "configured but not effective" failure check B5 exists to catch -- and the symptom would be a
# kiosk machine with a working Ctrl+Alt+F2, found by a student rather than by CI.
#
# So: try the two offline spellings, then FALL BACK TO CREATING THE SYMLINKS ourselves, then VERIFY
# on the filesystem. "enabled" and "masked" are filesystem states, not daemon opinions.
#
# build/00-common.sh has equivalent functions. These are deliberately not shared with it: apply-policy
# also runs from a customer recipe's layer, where 90-cleanup.sh has already deleted /tmp/auros-build
# and 00-common.sh is not on the image. Two implementations of a filesystem fact are safer here than
# one implementation that is sometimes absent.

_auros_systemctl_offline() {
    SYSTEMD_OFFLINE=1 systemctl --root=/ "$@" >/dev/null 2>&1 && return 0
    SYSTEMD_OFFLINE=1 systemctl "$@" >/dev/null 2>&1 && return 0
    return 1
}

auros_unit_file() {
    local u="$1" f
    for f in "/etc/systemd/system/$u" "/usr/lib/systemd/system/$u" "/lib/systemd/system/$u"; do
        [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}
auros_unit_exists() { auros_unit_file "$1" >/dev/null 2>&1; }

auros_unit_enable() {
    local u="$1" f t linked=0
    if ! f="$(auros_unit_file "$u")"; then
        log "unit $u is not on this image; nothing to enable"
        return 0
    fi
    _auros_systemctl_offline enable --no-reload "$u" || true
    for t in $(sed -n 's/^WantedBy=//p' "$f" | tr ' ' '\n' | grep -v '^$'); do
        if [ -e "/etc/systemd/system/$t.wants/$u" ] || [ -e "/usr/lib/systemd/system/$t.wants/$u" ]; then
            linked=1; continue
        fi
        # /usr, not /etc: on a bootc host an image update replaces /usr wholesale while /etc is
        # machine-local and three-way merged, so a default that belongs to the image belongs in /usr.
        # An administrator can still override it with a masking symlink in /etc.
        mkdir -p "/usr/lib/systemd/system/$t.wants"
        ln -sfn "../$u" "/usr/lib/systemd/system/$t.wants/$u"
        [ -e "/usr/lib/systemd/system/$t.wants/$u" ] || die "could not enable $u for $t"
        linked=1
        log "enabled $u for $t by symlink (offline systemctl did not do it)"
    done
    [ "$linked" -eq 1 ] || die "$u has no WantedBy target, so it cannot be enabled. A unit that can only be started by hand is not an enabled unit, and on a kiosk machine there is nobody to start it by hand."
    log "enabled $u"
}

auros_unit_disable() {
    local u="$1"
    auros_unit_exists "$u" || return 0
    _auros_systemctl_offline disable --no-reload "$u" || true
    log "disabled $u"
}

# Masked, not disabled. A disabled unit is one `systemctl enable` away from running, and socket-,
# dbus- and path-activated units start on activation even while disabled. Masking points the unit at
# /dev/null and nothing can activate it.
#
# Unlike 00-common.sh's mask_unit, this one masks a unit that does NOT exist on the image as well,
# and on purpose: kiosk masks display-manager.service precisely because we just removed every
# package that could provide it, and the mask is what stops a later layer reintroducing one.
auros_unit_mask() {
    local u="$1" link="/etc/systemd/system/$1"
    _auros_systemctl_offline mask --no-reload "$u" || true
    mkdir -p /etc/systemd/system
    ln -sfn /dev/null "$link"
    [ "$(readlink -f "$link" 2>/dev/null || true)" = "/dev/null" ] \
        || die "failed to mask $u -- $link is not a link to /dev/null. A mask that did not take is a door we told the customer was closed."
    printf '%s\n' "$u" >> "$AUROS_MASKED_UNITS"
    log "masked $u"
}

auros_unmask_previous() {
    local u count=0 link
    [ -r "$AUROS_MASKED_UNITS" ] || return 0
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        link="/etc/systemd/system/$u"
        if [ -L "$link" ] && [ "$(readlink -f "$link" 2>/dev/null || true)" = "/dev/null" ]; then
            rm -f "$link"
            count=$(( count + 1 ))
        fi
        _auros_systemctl_offline unmask --no-reload "$u" || true
    done < "$AUROS_MASKED_UNITS"
    log "unmasked $count units masked by the previous policy mode"
    : > "$AUROS_MASKED_UNITS"
}

# ── PAM: restrict su to the administrative group ─────────────────────────────────────────────────
# SHARED FILE (/etc/pam.d/su). Guarded by a marker and idempotent. pam_rootok stays first, so root
# keeps working and repair paths are unaffected.
auros_pam_su_restrict() {
    local f=/etc/pam.d/su
    local marker='# auros-policy: su is restricted to the aurosadmin group'
    [ -f "$f" ] || { warn "$f not found; su is not restricted by PAM"; return 0; }
    if grep -qF "$marker" "$f"; then log "su already restricted by PAM"; return 0; fi

    local tmp rootok
    tmp="$(mktemp)"
    # pam_rootok MUST come first, or root cannot su either and every repair path on the machine is
    # gone. Fedora's stock /etc/pam.d/su has it; if this image's does not, we add one rather than
    # locking root out of its own machine.
    rootok="$(grep -m1 'pam_rootok' "$f" || true)"
    [ -n "$rootok" ] || rootok="$(printf 'auth\t\tsufficient\tpam_rootok.so')"
    {
        printf '%s\n' "$marker"
        printf '%s\n' "$rootok"
        printf 'auth\t\trequired\tpam_wheel.so use_uid group=aurosadmin\n'
        grep -v 'pam_rootok' "$f"
    } > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
    chmod 0644 "$f"
    log "restricted su to the aurosadmin group in $f"
}

auros_pam_su_release() {
    local f=/etc/pam.d/su
    local marker='# auros-policy: su is restricted to the aurosadmin group'
    [ -f "$f" ] || return 0
    grep -qF "$marker" "$f" || return 0
    sed -i -e "/^${marker}$/d" -e '/pam_wheel.so use_uid group=aurosadmin/d' "$f"
    log "released the PAM su restriction"
}

# ── the administrative group ─────────────────────────────────────────────────────────────────────
auros_ensure_admin_group() {
    getent group aurosadmin >/dev/null 2>&1 || groupadd -r aurosadmin
    local u added=""
    for u in ${AUROS_ADMIN_USERS:-}; do
        if id "$u" >/dev/null 2>&1; then
            usermod -aG aurosadmin "$u" && added="$added $u"
        else
            warn "AUROS_ADMIN_USERS names '$u', which does not exist on this image"
        fi
    done
    if [ -n "$added" ]; then
        log "added to aurosadmin:$added"
    else
        cat >&2 <<'EOW'
auros[policy]  ! ---------------------------------------------------------------------------
auros[policy]  ! the aurosadmin group has no members on this image.
auros[policy]  !
auros[policy]  ! In managed and locked, aurosadmin is the ONLY administrative identity: sudo
auros[policy]  ! grants it and polkit names it as the admin. An image built like this has no
auros[policy]  ! administrator at the seat at all -- which is safe, and is also probably not
auros[policy]  ! what the customer wanted.
auros[policy]  !
auros[policy]  ! The first-boot setup layer is what puts the school's IT account in the group.
auros[policy]  ! To set it here instead, pass AUROS_ADMIN_USERS="name" to apply-policy.
auros[policy]  ! ---------------------------------------------------------------------------
EOW
    fi
}

# ── JSON ─────────────────────────────────────────────────────────────────────────────────────────
auros_json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'; }
