# Why `policy.json` looks like that, and why it has no comments in it

`policy.json` is the file that makes D8 true. It is also the file most likely to be "tidied" by
someone who does not know what each line is load-bearing for. This is that knowledge.

## It may not contain comments. At all.

`containers/image` parses this file with `internal.ParanoidUnmarshalJSONObject`, which returns an
error for **any key it does not recognise** — see `Policy.UnmarshalJSON` in
`containers/image/signature/policy_config.go`. A `$comment` key, or a `//`, does not get ignored:
it makes the whole policy fail to load. The manual's examples show `/* … */` because they are
illustrative JS, not because the parser accepts them.

A policy that fails to load is not a policy that fails open — but it is a machine that cannot
pull anything, including its own updates, and the error text does not say "you added a comment".
`build/30-update-agent.sh` re-implements the same strictness at build time so this is caught in
CI and never on a laptop.

## `"default": [{"type": "reject"}]` — not `insecureAcceptAnything`

bootc's `enforce-container-sigpolicy` guard reads the **global default only**
(`is_default_insecure()` in `bootc/crates/ostree-ext/src/container/skopeo.rs`). Fedora's stock
policy has `insecureAcceptAnything` as the global default, so with it the guard fails. With
`reject`, it passes, and every transport that needs to keep working is re-permitted explicitly
below.

## Scope precedence is *specificity*, not order

D8 says the `sigstoreSigned` entry must come "before any catch-all". That is the right intent
expressed in the wrong mechanism, and the distinction matters if anyone ever reorders the file.
JSON objects are unordered and `containers/image` does not read them in order. From
`containers-policy.json(5)`:

> If multiple policy requirements match a given image, only the requirements from the most
> specific match apply, the more general policy requirements definitions are ignored.

So `ghcr.io/<namespace>` beats `""` for our images because it is a **longer scope**. Reordering
the file changes nothing. Deleting the scoped entry silently disables enforcement while leaving a
file that still looks like it enforces something — which is exactly the D8 failure, reproduced in
our own repo instead of inherited from Aurora's.

## The `""` catch-all stays, deliberately

Setting `transports.docker[""]` to `reject` would break distrobox, toolbox, and every other image
a user legitimately pulls. The trade, stated plainly so nobody discovers it later: **our namespace
is enforced; every other registry behaves exactly as it does on any Fedora desktop.** We are not
selling a machine that can only run our containers; we are selling a machine that cannot be
updated by anyone but us.

`verify-enforcement.sh` is what proves the scoped entry actually beats the catch-all, by offering
the machine an unsigned image **inside our own namespace** and requiring refusal. If the catch-all
were winning, that image would be accepted and the check would fail. That is the test's whole job.

## `signedIdentity: matchRepository` is mandatory

From the manual: "cosign-created signatures only contain a repository, so only `matchRepository`
and `exactRepository` can be used to accept them". The default is `matchExact`, which would reject
**every** signature we ever produce.

This is the single most dangerous line to get wrong, because getting it wrong makes the *negative*
test pass. "The unsigned image was refused" is also true when everything is refused. That is why
`verify-enforcement.sh` runs a **positive control first** and exits INCONCLUSIVE — never "pass" —
if the correctly signed image is refused.

## `keyPath`, not `fulcio`

See `README.md` § "Keyless does not work for our consumer". Short version: `containers/image`
matches Fulcio certificate identities against `EmailAddresses` SANs only, and GitHub Actions OIDC
certificates carry a **URI** SAN. The `fulcio` block cannot express our CI identity today.
