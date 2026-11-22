# build-vm

Light CI build VM: a self-hosted GitHub Actions runner on Hyper-V.

- **The image** is built by the `image` pipeline in this repository (Packer,
  infrastructure as code) and published as a GitHub release.
- **`host/BuildVm.ps1`** on your Windows PC downloads the image, creates the
  VM and adds or removes the runners and the `RUNNER` variable in the
  repositories with `gh`.

The VM is close to the GitHub-hosted `ubuntu-24.04` runner, but it has only
the tools that the CI pipelines need. Jobs run directly on the VM, so
Docker works with no Docker-in-Docker.

## Quick start (Windows)

Needs: Hyper-V, [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
(`winget install Microsoft.PowerShell`), [GitHub CLI](https://cli.github.com/)
(`winget install GitHub.cli`, then `gh auth login`) and the OpenSSH client
(part of Windows). Run in an **admin** PowerShell 7:

```powershell
git clone https://github.com/pandasoft-zz/build-vm
cd build-vm\host
Copy-Item buildvm.config.example.psd1 buildvm.config.psd1
notepad buildvm.config.psd1   # set Repos (and CPUs, RAM, disk, switch)
.\BuildVm.ps1 Install         # download the newest image, create and start the VM
.\BuildVm.ps1 Register        # add runners and set RUNNER=build-vm in all repositories
.\BuildVm.ps1 Status
```

Jobs now run on the VM. `buildvm.config.psd1` is in `.gitignore`, so your
list of repositories stays on your PC.

## BuildVm.ps1 commands

| Command | What it does |
| --- | --- |
| `Install [-Version v1.0.0 \| -ImagePath x.vhdx]` | Download the image (newest release by default), check SHA-256, create the VM, start it. `-ImagePath` uses a local VHDX instead |
| `Register [-Repo o/r]` | Add `RunnersPerRepo` runners for each repository and set the `RUNNER` variable |
| `Unregister [-Repo o/r]` | Remove the runners and the `RUNNER` variable |
| `Enable [-Repo o/r]` | Set `RUNNER` only: jobs go to the VM |
| `Disable [-Repo o/r]` | Remove `RUNNER` only: jobs go to GitHub-hosted runners |
| `Start` / `Stop` | Start the VM (and wait until it is ready) / shut it down |
| `Status` | VM state and IP, and for each repository the variable and the runner state |
| `Ssh` | SSH session to the VM |
| `Update [-Version v1.1.0 \| -ImagePath x.vhdx]` | Unregister, remove the VM, install the new image, register again |
| `Remove` | Unregister and delete the VM with its files |

Without `-Repo` a command works on all repositories from the config. When
the VM is off, jobs wait in the queue; `Disable` sends them to GitHub-hosted
runners instead.

A GitHub runner runs **one job at a time**. With `RunnersPerRepo = 2` (or
more) in the config, `Register` adds runners `<vm>-<owner>-<repo>-1`, `-2`,
..., so jobs of one repository run in parallel. Each runner has its own
folder, `HOME` and work folder (`HOME/work`, the same layout as on
GitHub-hosted runners). Give the VM enough CPUs and RAM (`Cpus`, `MemoryGB`)
for the parallel jobs. Runners of a personal account belong to one
repository, so each repository has its own runners.

The workflows in the repositories use:

```yaml
runs-on: ${{ vars.RUNNER || 'ubuntu-latest' }}
```

## How it works

```
GitHub Actions (this repo)                Your PC (Hyper-V)
-------------------------                 ------------------------------------
Packer + QEMU/KVM: Ubuntu 24.04           BuildVm.ps1 Install
  autoinstall + provisioning      ---->     gh release download, check SHA-256
qemu-img -> VHDX, gzip, split             VM Generation 2, Secure Boot
GitHub release (assets)                   cloud-init seed disk: SSH key, name
                                          BuildVm.ps1 Register
                                            gh: registration token
                                            ssh: runner-add in the VM
                                            gh: variable RUNNER
```

- The image has **no secret**. The build password is random and is locked at
  the end of the build. Each VM gets a new SSH key (in the VM folder) and its
  host name from a small cloud-init seed disk (`seed.vhdx`, label `CIDATA`).
- **SSH trust goes both ways, with no trust on first use.** `Install` also
  makes the SSH host key of the VM, puts it on the seed disk and writes its
  public part to `known_hosts` before the VM starts. SSH runs with
  `StrictHostKeyChecking=yes`, so a wrong machine at the VM IP address is
  refused. After the first boot `Install` turns cloud-init off in the VM,
  removes the seed disk and deletes the private host key from the PC.
- GitHub tokens never go into the VM config: `BuildVm.ps1` gets short-lived
  registration tokens with `gh` and sends them over SSH (stdin).
- Each repository has its own runner service (a personal account cannot
  share one runner across repositories). They can run jobs at the same time;
  the pipelines use random host ports for service containers. Watch the RAM:
  a Gradle build and a Docker build together need most of 8 GB.

## What is in the image

| Part | Why |
| --- | --- |
| Ubuntu Server 24.04 | Same OS as `ubuntu-latest` / `ubuntu-24.04` |
| Docker Engine + compose + buildx | Service containers, `docker build`, Renovate action |
| Passwordless `sudo` | Jobs run `sudo apt-get install ...` |
| `build-essential`, `git`, `curl`, `jq`, `unzip`, `shellcheck`, `yamllint`, ... | Basic job tools, the small ones of the GitHub-hosted image |
| Python 3 with `python3-yaml`, `python` = `python3` | Repository scripts that read YAML |
| `kubectl`, `helm` (major 3), `kustomize`, `yq` | Scripts call them without a setup action, as on GitHub-hosted runners |
| `libvips-dev` | Go image library builds (govips), installed before the job asks |
| GitHub CLI `gh`, Node.js LTS | Jobs call `gh` and `npx` without a setup action |
| Android SDK in `/usr/local/lib/android/sdk` | Android builds; `ANDROID_HOME` is set for each job |
| Hyper-V tools (KVP daemon) | Hyper-V and `BuildVm.ps1` see the VM IP address |
| `actions/runner` + `runner-add`, `runner-remove`, `runner-list` | One runner service for each repository |
| Empty `HOME` for each job (job-started hook) | Nothing stays from the job before, like on a new GitHub VM |
| Weekly Docker clean-up (systemd timer) | The disk does not fill up |

Go, other Java and Node versions, cloud CLIs (AWS, Azure, gcloud) and
browsers are not in the image. The `setup-*` actions download them into the
runner tool cache, the same as on GitHub; a `setup-*` action also puts its
own Helm or kubectl version before the one in the image. Caches
(`actions/cache`, `setup-gradle`) use the GitHub cache service.

## Build a new image

Push a tag, or run the `image` workflow by hand with a new tag name:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow takes about 30-60 minutes. It builds on a GitHub-hosted Linux
runner with KVM, which is free for a public repository. The release has the
gzip parts of the VHDX (each under the 2 GiB asset limit), `SHA256SUMS` and
`build-vm.vhdx.sha256`. Then run `.\BuildVm.ps1 Update -Version v1.0.0`.

### Local build on Hyper-V

To test changes without the pipeline, build the image on your PC with the
Packer source `hyperv-iso`. It needs [Packer](https://developer.hashicorp.com/packer/install)
in `PATH` and admin rights or the group Hyper-V Administrators:

```powershell
cd packer
.\build-local.ps1               # about 10-20 minutes
```

The VHDX is in `packer\output-hyperv\Virtual Hard Disks\`. Install it with
`.\BuildVm.ps1 Install -ImagePath '..\packer\output-hyperv\Virtual Hard Disks\packer-build-vm.vhdx'`
(or `Update -ImagePath ...` for an installed VM). The script gives
Packer the IP address of the host on the switch (`Default Switch`), because
with several vEthernet adapters Packer can pick the wrong one. Windows
Firewall must let the VM reach the Packer HTTP server: if the firewall dialog
made a **Block** rule for `packer-plugin-hyperv`, remove it in an admin
PowerShell:

```powershell
Get-NetFirewallRule -DisplayName 'packer-plugin-hyperv*' | Where-Object Action -eq Block | Remove-NetFirewallRule
```

## Folders

```
.github/workflows/  image (build + release), lint (Packer, ShellCheck, PSScriptAnalyzer)
packer/             Packer template, autoinstall config, provisioning scripts
vm/                 Files copied into the image (runner scripts, systemd units)
host/               BuildVm.ps1 and its config
```

## Security

Use this runner only for private repositories. A job can run any code on the
VM, and a pull request from a fork of a public repository could do the same.
See [Security hardening for self-hosted runners](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners).
