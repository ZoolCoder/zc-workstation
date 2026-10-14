# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting — [Security → Report a
vulnerability](https://github.com/ZoolCoder/zc-workstation/security/advisories/new) — or
email the maintainer listed on the repository profile.

You will get an acknowledgement within a few days. This is a small project with
one maintainer, so please be patient; if a fix takes longer than that, you will
be told where it stands rather than left waiting.

## What is in scope

`zc-workstation` writes changes to the targets its config names, so the
interesting failures are about writing somewhere it should not and about doing
something the operator did not review.

Especially in scope:

* **A write outside a target.** The `localdir` provider writes through
  `os.Root`, so a symlink or a `..` in a file name cannot lead a write out of
  the target directory. A way around that is a vulnerability.
* **Applying something that was not planned.** A saved plan that applies after
  the world moved, or an action executing that the plan did not list.
* **A `MANUAL` action executing.** Those never have a `Do`.
* **The admin page reachable from elsewhere.** `zc-workstation ui` has no
  login; it refuses a non-loopback address, answers 403 to a foreign `Host`
  header (DNS rebinding) and to a cross-site `POST`. A way past any of the
  three is a vulnerability.
* **An agent applying without the operator.** The MCP server's `apply` takes
  only the id of a plan it saved and never a plan body, and a plan that
  deletes goes back to the operator's terminal; the plugin's hook asks before
  an `apply` with `-yes`. A path where an agent applies something the operator
  was not shown is in scope.

## What is not in scope

* **A hostile config file.** A config can name any directory you can write to.
  Review a config you did not write, as you would any script.
* **Anything requiring an attacker to already have your shell.**

## Supported versions

The latest release.

## What you can expect from a fix

A security fix gets a release of its own, notes saying what was exposed and
under what conditions, and a test that fails without the fix.
