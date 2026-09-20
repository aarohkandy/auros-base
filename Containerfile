# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# AUROS BASE — ghcr.io/aarohkandy/auros-base:hardened
#
# THERE IS EXACTLY ONE OF THESE. Not one per customer, not one per hardware generation, not one per
# policy mode. Every customer recipe derives from this image and may only ADD to it (spec §3). The
# reason is the thing we actually sell: a CVE response is one rebuild of this file, which propagates
# to every recipe and every machine. A second base would end that property, and the property is the
# product.
#
# Build:
#   podman build -t localhost/auros-base:hardened -f Containerfile .
#
# The published image is NOT this image: the publish workflow flattens it with
# `rpm-ostree compose build-chunked-oci --bootc` (DECISIONS.md D11 / D2) so that packages a recipe
# pruned are bytes the customer never downloads, and so that a nightly rebuild moves a bounded subset
# of layers rather than 3.5 GB per machine (BLOCKED.md B6).
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

# ── The pinned upstream ─────────────────────────────────────────────────────────────────────────
# This digest is the one in base.lock, and check S1 fails the build if the FROM here does not resolve
# to exactly it. A tag would be a moving target: two builds a day apart would be different operating
# systems wearing the same name, and "same recipe in, same image out" would stop being true.
#
# base.lock is resolved by CI and never edited by hand. It is also COPYed into the build below, where
# build/00-common.sh asserts that the digest the Containerfile declares and the digest base.lock
# records are the same string. A build cannot introspect its own FROM line, so that in-image check
# catches the realistic mistake — one of the two edited without the other — while check S1, run from
# outside against the resolved parent, is the authoritative one.
#
# Written as a literal rather than through an ARG so that the digest is greppable from this line by a
# checker that does not have to evaluate build arguments to find it.
FROM ghcr.io/ublue-os/aurora@sha256:911281f2aaa42bfd17532c5cef917aba8d7ac8c0faeb1c1edc6a43dc28d0d2f1

# Same three values again, as build arguments, so the build scripts and the OCI labels can see them.
# 00-common.sh compares UPSTREAM_DIGEST against base.lock and fails the build on a mismatch.
ARG UPSTREAM_IMAGE=ghcr.io/ublue-os/aurora
ARG UPSTREAM_TAG=stable
ARG UPSTREAM_DIGEST=sha256:911281f2aaa42bfd17532c5cef917aba8d7ac8c0faeb1c1edc6a43dc28d0d2f1

# Fixed build clock. Every file the build writes is stamped with this, so that two builds from
# identical inputs differ in as few bytes as possible (check S7). The default is the upstream base
# image's own creation time (2026-09-15T20:33:50Z, recorded in base.lock as UPSTREAM_CREATED) rather
# than 0, because a 1970 mtime on a system file confuses enough tooling to be its own problem.
ARG SOURCE_DATE_EPOCH=1789504430

# No ENV for any of the above, deliberately. Build arguments are already exposed to RUN as
# environment variables, which is how build/00-common.sh reads UPSTREAM_DIGEST and SOURCE_DATE_EPOCH;
# an ENV would additionally bake them into the published image's environment, where SOURCE_DATE_EPOCH
# in particular would then be inherited by every process on a customer's laptop forever.

# -euo pipefail for every RUN below, rather than repeated at the top of each one. A build step that
# fails quietly in the middle of a pipeline is how an image ships half-hardened.
SHELL ["/usr/bin/bash", "-euo", "pipefail", "-c"]

# ── The build context ───────────────────────────────────────────────────────────────────────────
# THE CONVENTION: build/*.sh run in numeric order inside the image build. Each script is idempotent,
# sets -euo pipefail, and echoes what it did — that output is what the website's build console
# streams, so it has to be true.
#
# A step's data files can live in either of two places:
#
#   build/<nn>-<name>.d/    beside the script. Copied automatically with build/, no coordination.
#                           PREFER THIS when adding a step.
#   <name>/                 a top-level directory, which needs its own COPY line below.
#
# Directories are enumerated rather than `COPY . /tmp/auros-build/` on purpose: .git, .github/ and
# matrix/ would otherwise enter the image build, and .git in particular carries content that differs
# between two builds of the same tree, which is a direct S7 determinism failure.
#
# IF YOU ADD A TOP-LEVEL DATA DIRECTORY, ADD IT HERE IN THE SAME CHANGE. build/00-common.sh prints,
# for every step it is about to run, which of its data directories it can actually see — so a missing
# COPY shows up as a named line in the build log rather than as a mysterious failure forty lines on.
COPY build/        /tmp/auros-build/build/
COPY base.lock     /tmp/auros-build/base.lock
COPY hardening/    /tmp/auros-build/hardening/
COPY policy/       /tmp/auros-build/policy/
COPY update-agent/ /tmp/auros-build/update-agent/
COPY signing/      /tmp/auros-build/signing/
COPY desktop/      /tmp/auros-build/desktop/

# `tools/` is deliberately NOT copied: those are CI-side helpers that run on the runner against the
# registry, not inside the image. Neither is `matrix/` — the check matrix is what judges the image,
# and an image that carries its own grading criteria is not being graded by them.

# ── The build ───────────────────────────────────────────────────────────────────────────────────
# One RUN. Every step, then the cleanup that removes all of them, in a single layer — so the image
# filesystem this layer produces contains nothing from the build. (The COPY layer above still
# physically holds the build inputs until the publish-time flatten rebuilds the image from the
# committed filesystem; see D11. After 90-cleanup.sh, no path under /tmp/auros-build exists.)
RUN chmod 0755 /tmp/auros-build/build/*.sh && \
    for _auros_step in $(ls -1 /tmp/auros-build/build/[0-9][0-9]-*.sh | sort); do \
        printf '\n══════════════════════════════════════════════════════════════════════════\n'; \
        printf 'auros: running %s\n' "$(basename "$_auros_step")"; \
        printf '══════════════════════════════════════════════════════════════════════════\n'; \
        "$_auros_step" || { printf 'auros: FAILED in %s\n' "$(basename "$_auros_step")" >&2; exit 1; }; \
    done && \
    test ! -e /tmp/auros-build || { printf 'auros: build context survived cleanup\n' >&2; exit 1; }

# ── Commit and lint ─────────────────────────────────────────────────────────────────────────────
# `ostree container commit` is the ostree-side finalisation: it clears /var (which is machine-local
# state that an image has no business carrying) and prepares the filesystem for use as an ostree
# container. It is the last thing that touches the filesystem.
#
# `bootc container lint` is check S2, run here as well as in CI. Here it fails the build at the point
# of damage; in CI it is the gate. It is deliberately NOT tolerated with `|| true` — an image that is
# structurally incapable of being a bootable host is worth nothing, and finding that out at build
# time is strictly better than finding it out in QEMU.
RUN ostree container commit && \
    bootc container lint

# ── OCI labels ──────────────────────────────────────────────────────────────────────────────────
# Placed after the build so that a change to a label does not invalidate the build cache for every
# step above it.
#
# org.opencontainers.image.base.digest is the same string as base.lock's UPSTREAM_DIGEST and as the
# FROM line. It travels with the published image, so anyone — customer, auditor, us in four years —
# can ask a registry what upstream a given Auros image was built from without access to this repo.
LABEL org.opencontainers.image.title="auros-base"
LABEL org.opencontainers.image.description="The single Auros base image. Fedora bootc via Universal Blue Aurora, pinned by digest, with signature-verification trust material, SELinux enforcing, sshd masked, a default-deny firewall and automatic rollback. Every Auros customer recipe derives from exactly this image and may only add to it, so a CVE response is one rebuild."
LABEL org.opencontainers.image.source="https://github.com/aarohkandy/auros-base"
LABEL org.opencontainers.image.documentation="https://github.com/aarohkandy/auros-base/blob/main/README.md"
LABEL org.opencontainers.image.url="https://github.com/aarohkandy/auros-base"
LABEL org.opencontainers.image.vendor="Auros"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.base.name="${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
LABEL org.opencontainers.image.base.digest="${UPSTREAM_DIGEST}"

# Auros-specific. `recipe` is "base" because this IS the base; customer recipes overwrite it with
# their own name, which is how a machine in the field can say which recipe it is running.
LABEL dev.auros.recipe="base"
LABEL dev.auros.image.kind="base"
LABEL dev.auros.upstream.image="${UPSTREAM_IMAGE}"
LABEL dev.auros.upstream.tag="${UPSTREAM_TAG}"
LABEL dev.auros.upstream.digest="${UPSTREAM_DIGEST}"

# Marks this as a bootc-bootable host image rather than an application container.
LABEL containers.bootc="1"
