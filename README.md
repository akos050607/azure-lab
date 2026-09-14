# azure-lab

Azure, built by hand and then declared, as the counterpart to
[`homelab-platform`](https://github.com/akos050607/homelab-platform) — which runs
the same ideas on Hetzner and k3s.

**Nothing here stays up.** Every session ends with `az group delete`, and the
repository is the artifact that survives. That is the same property the homelab
cluster has, for the same reason: infrastructure that exists only as a running
machine is infrastructure you cannot prove anything about.

| Session | What it covers | State |
|---|---|---|
| 1 | Subscription, resource group, region, one VM, blast-radius delete | done |
| **2** | **VNet, subnet, NSG, public IP, NIC, VM — assembled piece by piece** | **done, this commit** |
| **3** | **The same network declared in Terraform with `azurerm`** | **done, this commit** |
| 4 | k3s on an Azure VM — what changes versus Hetzner | planned |
| 5 | Managed identity + Key Vault, no secret on the box | planned |

---

## Session 2 — the network

Built with `az` one resource at a time rather than letting `az vm create` invent
them, because the point was to know what each piece is for.

```
rg-net-01                     germanywestcentral
 └── vnet-lab                 10.10.0.0/16
      └── snet-app            10.10.1.0/24   ← nsg-app attached HERE (subnet, not NIC)
           └── nic-app        10.10.1.4
                └── vm-app    Standard_D2als_v7, zone 1
                     └── pip-app   Standard, Static
```

```bash
az group create -n rg-net-01 -l germanywestcentral \
  --tags owner=akos purpose=interview-lab session=B3-S2

az network vnet create -g rg-net-01 -n vnet-lab \
  --address-prefix 10.10.0.0/16 \
  --subnet-name snet-app --subnet-prefix 10.10.1.0/24

az network nsg create -g rg-net-01 -n nsg-app
az network nsg rule create -g rg-net-01 --nsg-name nsg-app -n allow-ssh \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes <my-ip>/32 --destination-port-ranges 22
az network nsg rule create -g rg-net-01 --nsg-name nsg-app -n allow-https \
  --priority 110 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes Internet --destination-port-ranges 443

az network vnet subnet update -g rg-net-01 --vnet-name vnet-lab -n snet-app \
  --network-security-group nsg-app

az network public-ip create -g rg-net-01 -n pip-app --sku Standard --allocation-method Static
az network nic create -g rg-net-01 -n nic-app --vnet-name vnet-lab --subnet snet-app \
  --public-ip-address pip-app

az vm create -g rg-net-01 -n vm-app --nics nic-app \
  --image Ubuntu2404 --size Standard_D2als_v7 --zone 1 \
  --admin-username akos --ssh-key-values ~/.ssh/id_ed25519.pub
```

### Why `10.10.0.0/16`

Chosen against a written list, not picked because it looked free:

```
10.42.0.0/16    k3s pod CIDR        (homelab)
10.43.0.0/16    k3s service CIDR    (homelab)
100.64.0.0/10   Tailscale           (CGNAT range)
10.10.0.0/16    this lab            no overlap with any of the above
```

An evening was already lost in the homelab to a `10.42.0.0/24` collision between
k3s and a NetworkManager hotspot. Writing three lines down before creating a VNet
costs thirty seconds.

### Why the NSG is on the subnet, not the NIC

An NSG can attach at **either** level, and if you attach at both, **both are
evaluated** — inbound subnet-first, outbound NIC-first. Two places to change one
rule is two places to forget.

That is the same failure class as declaring `replicas` on a Deployment that an
HPA also owns, or letting CI `kubectl apply` into a cluster Argo CD is
reconciling. **One writer per field.** Picked the subnet and stayed there.

---

## What Session 2 measured

Evidence in [`evidence/`](evidence/). The two that matter:

### Dropped is not refused

| Target | NSG state | Result |
|---|---|---|
| `:22` | `allow-ssh` present | **connected in 0.04 s**, SSH banner |
| `:22` | `allow-ssh` deleted | **timeout after 12 s** |
| `:8080` | no rule → default | **timeout after 12 s** |

An NSG **drops**: nothing answers, so the client waits out its own timeout. A
*refused* connection is the opposite signal — something replied with a RST, so
the host is reachable and nothing is listening.

> **timeout → suspect the network · refused → suspect the process**

### Ask which rule matched; don't theorise

```
allow-ssh deleted   →  { "access": "Deny",  "ruleName": "defaultSecurityRules/DenyAllInBound" }
allow-ssh restored  →  { "access": "Allow", "ruleName": "securityRules/allow-ssh" }
```

`az network watcher test-ip-flow` answers the question directly. Same instinct as
reading `ip route get` instead of guessing which route was wrong — which is what
actually solved the homelab CIDR collision.

### The rules you cannot delete

```
INBOUND                                  OUTBOUND
100    allow-ssh            Allow        65000  AllowVnetOutBound      Allow
110    allow-https          Allow        65001  AllowInternetOutBound  Allow
65000  AllowVnetInBound     Allow        65500  DenyAllOutBound        Deny
65001  AllowAzureLBInBound  Allow
65500  DenyAllInBound       Deny
```

Priorities 100–4096 are yours; 65000+ belong to Azure. Lowest number wins and the
first match stops evaluation, so a default can be **overridden by a lower number
but never removed**. Note that outbound is open by default — the deny-all sits
below an allow-internet rule.

NSGs are **stateful**: allow inbound 443 and the reply leaves without an outbound
rule.

---

## Session 3 — the same network, declared

Session 2's eight `az` commands, rewritten as HCL. `terraform apply` produced a
network that behaves identically, and `terraform destroy` removed all of it.

```bash
cp example.tfvars terraform.tfvars   # subscription id + your own IP
terraform init
terraform plan -out=tfplan           # 10 to add, 0 to change, 0 to destroy
terraform apply tfplan
ssh akos@$(terraform output -raw public_ip)
terraform destroy
```

### Ten resources for one machine

`az vm create` hides this; Terraform cannot. The same VM that is **one**
`hcloud_server` on Hetzner is ten declarations here:

```
azurerm_resource_group.lab
azurerm_virtual_network.lab
azurerm_subnet.app
azurerm_network_security_group.app
azurerm_network_security_rule.ssh
azurerm_network_security_rule.https
azurerm_subnet_network_security_group_association.app
azurerm_public_ip.app
azurerm_network_interface.app
azurerm_linux_virtual_machine.app
```

That verbosity is not Terraform being awkward. Azure genuinely models the
network card and the public address as separate things with their own
lifecycles — which is also why deleting a VM alone leaves you paying for its
disk and its IP.

### The association is its own resource, and that is the point

`azurerm_subnet` will happily accept a `network_security_group_id` inline. Set it
there **and** declare `azurerm_subnet_network_security_group_association` and
every apply flaps: one writer sets the field, the other clears it, forever.
Terraform reports a diff on every run and neither side is wrong — they simply
both believe they own that field.

That is the same failure as an HPA and a Deployment both owning `replicas`, and
as CI running `kubectl apply` into a cluster Argo CD reconciles. **One writer per
field**, and the rule holds across tools.

The check that proves it:

```
$ terraform plan -detailed-exitcode
No changes. Your infrastructure matches the configuration.
exit code: 0
```

An empty second plan is the evidence. A config with two owners can never produce
one.

### Two things azurerm 4 will not let you skip

**`features {}`** — required even when empty. It is where provider-wide
behaviours live, such as whether `destroy` may remove a non-empty resource group.

**`subscription_id`** — mandatory from v4 onward. Earlier versions silently
inherited whatever `az login` had selected, which is a pleasant default right up
until it applies to the wrong subscription.

### How this would authenticate without a human

Today Terraform is borrowing the `az login` session, which is fine on a laptop
and useless in a pipeline. The two real answers:

- A **service principal** — `az ad sp create-for-rbac --role Contributor --scopes /subscriptions/<id>` — supplying the four `ARM_*` environment variables. A long-lived credential that has to live in a secret store.
- **OIDC federation** from GitHub Actions, where the workflow exchanges a short-lived GitHub token for an Azure one and **no secret is stored at all**.

The second is the same idea as the managed identity in Session 5 and the same
idea as the GitOps pipeline in `homelab-gitops` holding no cluster credential:
the strongest secret is the one that never exists.

### hcloud versus azurerm

| | `hcloud` (homelab-platform) | `azurerm` (here) |
|---|---|---|
| Auth | API token in an env var | `az login`, service principal, or OIDC federation |
| Grouping | Project — created in the portal, not declarable | Resource group — a declarable resource with its own lifecycle |
| A server is… | one `hcloud_server` | ten resources |
| Firewall | `hcloud_firewall` attached to the server | NSG at subnet **or** NIC, priority-ordered, with undeletable defaults |
| Provisioning | `user_data` | `custom_data`, base64-encoded |
| Sizing | any type, any location | **restricted per subscription and per zone** — see FAILURES.md |
| State | local, no locking (ADR-001) | same here today; the production answer is a storage-account backend using blob leases |

The row that actually cost time was sizing. On Hetzner a server type either
exists or it does not. On Azure it can exist, be documented, be listed by the
CLI, and still be unavailable to your particular subscription in your particular
zone.

---

## Cost

A `$5/month` budget with alerts at 50 / 80 / 100 % was created **before** the
first resource, not after.

`az consumption budget create` is broken — it sends a stale API version and the
service rejects it:

```
(400) Invalid budget configuration, please use filter interface with 2019-05-01-preview version
```

Created through `az rest` against `2023-05-01` instead. The CLI is a wrapper over
the REST API, and dropping down to it is always available.

Other cost habits, because deleting the VM alone is not enough:
- Delete the **resource group**, never the VM — the OS disk and a Standard static
  public IP keep billing on their own.
- Standard SKU public IPs bill even while detached.
- Everything is tagged `owner` / `purpose` / `session` so cost can be attributed.

---

## What broke

See [`FAILURES.md`](FAILURES.md). Short version: `Standard_B1s` does not exist for
this subscription in this region and the error message says "Capacity
Restrictions" while meaning something else entirely; and a
`Permission denied (publickey)` that looked like a firewall problem and was a
local key passphrase.

---

## Honest floor

Lab Azure, not production Azure. Resource groups, VNet, subnet, NSG, public IP,
NIC and a VM — used, deleted, and rebuilt. No production traffic, no cost
pressure, no incident, no AKS, no multi-region, no managed database. Everything
that has actually been operated in anger is on Hetzner.
