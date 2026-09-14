# Azure lab — what broke

One line per thing that went wrong, written as it happened. Same purpose as
`docs/CHAOS-LOG.md` in homelab-platform: the failures are more useful than the
successes, because they are the only part nobody can fake.

## 2026-09-14 — Session 2, the network

### 1 · `Standard_B1s` does not exist for this subscription in this region

`az vm create --size Standard_B1s` failed preflight:

```
SkuNotAvailable: The requested VM size for resource 'Following SKUs have failed
for Capacity Restrictions: Standard_B1s' is currently not available in location
'GermanyWestCentral'.
```

- **First reading:** transient capacity shortage — the message literally says
  "Capacity Restrictions", so wait and retry.
- **Actually:** not transient. `az vm list-skus -l germanywestcentral` shows the
  restriction `reasonCode: NotAvailableForSubscription`. It is a property of this
  subscription (Azure for Students), not of the datacentre's current load.
- **The distinction that mattered.** Every SKU carries a list of restrictions,
  and they come in two types:

  | `type` | Meaning | Workaround |
  |---|---|---|
  | `Location` | blocked across the entire region | none — change region or SKU |
  | `Zone` | blocked only in the listed availability zones | deploy into a different zone |

  `Standard_B1s` and `Standard_B2s` are `Location`-restricted here: dead ends.
  `Standard_D2als_v7` is only `Zone`-restricted, and only in zone **2**.

- **Fix:** `--size Standard_D2als_v7 --zone 1`. Worked first try.
- **Why this is worth remembering:** "region vs availability zone" is normally
  vocabulary. Here it was the difference between a deployment that cannot work
  and one that works immediately, and reading the restriction *type* is what
  told them apart. Cloud capacity is not uniform, not infinite, and not the same
  for every subscription.

### 2 · `Permission denied (publickey)` that had nothing to do with the firewall

After the VM came up, SSH failed. The tempting conclusion is the NSG.

- **It was not.** The connection reached the SSH banner
  (`SSH-2.0-OpenSSH_9.6p1`), which means the TCP handshake completed and the
  NSG had already allowed the packet. A firewall problem cannot produce a
  banner.
- **Actual cause, entirely local:** the private key is passphrase-protected and
  the command ran with `BatchMode=yes`, which forbids prompting. No agent was
  running (`ssh-add -l` → `Error connecting to agent`).
- **Lesson, and it is the same one as the NSG demo below:** diagnose by layer.
  Getting a banner proves L3/L4 is fine and the problem is above it. Guessing
  "firewall" would have cost an hour of looking in the wrong place.

### 3 · `az consumption budget create` is broken

```
(400) Invalid budget configuration, please use filter interface with
2019-05-01-preview version
```

The CLI command is in preview and sends a stale API version. Created the budget
through `az rest` against the `2023-05-01` API instead. Worth knowing that the
CLI is a wrapper over the REST API and you can always drop down to it.

## Observations worth keeping

### Why the VNet is `10.10.0.0/16`

Chosen deliberately, not by default, because these ranges are already spoken for
in the homelab:

```
10.42.0.0/16    k3s pod CIDR
10.43.0.0/16    k3s service CIDR
100.64.0.0/10   Tailscale (CGNAT range)
10.10.0.0/16    ← this lab, no overlap with any of the above
```

An evening was already lost to a `10.42.0.0/24` collision between k3s and a
NetworkManager hotspot. Writing the ranges down before creating the VNet costs
thirty seconds.

### Dropped vs refused — measured, not read

Same VM, same moment, three TCP connects:

| Target | NSG state | Result |
|---|---|---|
| port 22 | `allow-ssh` present | **connected in 0.04 s**, SSH banner returned |
| port 22 | `allow-ssh` deleted | **timeout after 12 s** |
| port 8080 | no rule, falls to default | **timeout after 12 s** |

An NSG **drops** the packet — nothing answers, so the client waits out its own
timeout. A *refused* connection is the opposite signal: something answered with
a RST, so the host is reachable and simply nothing is listening. That is an
application problem, not a firewall problem.

**Timeout → suspect the network. Refused → suspect the process.**

### Asking instead of guessing

`az network watcher test-ip-flow` names the rule that decided:

```
rule deleted  →  { "access": "Deny",  "ruleName": "defaultSecurityRules/DenyAllInBound" }
rule restored →  { "access": "Allow", "ruleName": "securityRules/allow-ssh" }
```

Same instinct as reading `ip route get` instead of guessing which route was
wrong during the CIDR collision. The tool that answers the question beats the
theory that sounds right.

### The default rules you cannot delete

```
INBOUND                                   OUTBOUND
100    allow-ssh          Allow           65000  AllowVnetOutBound      Allow
110    allow-https        Allow           65001  AllowInternetOutBound  Allow
65000  AllowVnetInBound   Allow           65500  DenyAllOutBound        Deny
65001  AllowAzureLBInBound Allow
65500  DenyAllInBound     Deny
```

Priority 100–4096 is yours; 65000+ are Azure's. Lowest number wins and the first
match stops evaluation, so a default can only be overridden by a lower-numbered
rule, never removed. Note outbound is allowed by default — the deny-all sits
*below* an allow-internet rule.

## 2026-09-14 — Session 3, Terraform

### 4 · `description` in an `output` block cannot use variables

```
Error: Variables not allowed
  on outputs.tf line 2, in output "public_ip":
   2:   description = "ssh ${var.admin_username}@$(terraform output -raw public_ip)"
```

Trivial, but worth recording because the reason is not arbitrary: `description`
is documentation metadata, read by `terraform providers schema` and by docs
tooling without evaluating anything. It has to be a constant string. Interpolate
in `value`, never in `description`.

### Non-failures worth keeping

**The second plan was empty on the first try.** That was the outcome being aimed
for rather than luck — `azurerm_subnet` accepts an inline NSG id, and using it
*as well as* the association resource is the documented way to get a config that
diffs forever. Declaring the association only, and then checking
`terraform plan -detailed-exitcode` returns 0, is what turns "I think this is
right" into "I verified it".

**Ten resources, not eight.** Session 2 was eight `az` commands, but the plan
shows ten: the two NSG rules and the subnet↔NSG association are separate
resources in Terraform where `az` folded them into the commands that created
their parents. The count only matches once you stop thinking in commands and
start thinking in objects.

**The behaviour matched exactly.** Same probes as Session 2 against the declared
network: `:22` connected in 0.02 s, `:8080` timed out after 12 s. The point of
Session 3 is not that Terraform can make a VM — it is that the declared thing is
the same thing.
