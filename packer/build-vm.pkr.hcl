packer {
  required_version = ">= 1.11.0"
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "~> 1.1"
    }
  }
}

# The image is built with QEMU/KVM on a Linux CI runner and then converted to
# a Hyper-V VHDX (see .github/workflows/image.yml). For a local build on a
# Windows PC with Hyper-V, the source hyperv-iso makes the VHDX directly
# (start it with build-local.ps1).
# The image holds no secret:
# the build password is random and locked at the end. Each VM gets its SSH key
# and host name from a cloud-init seed disk (see host/BuildVm.ps1).

variable "vm_name" {
  type    = string
  default = "build-vm"
}

variable "iso_url" {
  type        = string
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso"
  description = "Ubuntu 24.04 live server ISO. Ubuntu keeps only the newest point release in this folder."
}

variable "iso_checksum" {
  type    = string
  default = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
}

variable "efi_firmware_code" {
  type        = string
  default     = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  description = "UEFI firmware (Ubuntu package ovmf). The VM on Hyper-V is Generation 2 (UEFI)."
}

variable "efi_firmware_vars" {
  type    = string
  default = "/usr/share/OVMF/OVMF_VARS_4M.fd"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "disk_size_gb" {
  type        = number
  default     = 40
  description = "Size of the image disk in GB. BuildVm.ps1 can make the VM disk bigger; cloud-init then grows the partition."
}

variable "http_ip" {
  type        = string
  default     = ""
  description = "Host IP address that the VM uses for the Packer HTTP server. Empty: Packer finds it. With several vEthernet adapters the Hyper-V plugin can pick the wrong one; build-local.ps1 sets the IP of the switch."
}

variable "hyperv_switch" {
  type        = string
  default     = "Default Switch"
  description = "Hyper-V virtual switch for the local build (source hyperv-iso). It needs DHCP and internet access."
}

variable "username" {
  type    = string
  default = "runner"
}

variable "build_password" {
  type        = string
  sensitive   = true
  description = "Password for SSH during the build only. The last script locks it."
}

variable "android_cmdline_tools_build" {
  type    = string
  default = "16111833"
}

variable "android_cmdline_tools_sha256" {
  type    = string
  default = "0877a1d048fe4a24efe2eff536ca4223f7adeb58648bb81909d33c446918cfa8"
}

variable "android_packages" {
  type        = list(string)
  default     = ["platform-tools", "platforms;android-36", "build-tools;36.0.0"]
  description = "Android SDK packages (sdkmanager names). Gradle installs other missing packages by itself."
}

variable "node_major" {
  type        = number
  default     = 22
  description = "Node.js major version (LTS) for jobs that call npx without setup-node."
}

# Tool versions without the 'v', each with the SHA-256 of its linux-amd64
# download. The build asks no API for versions, so the same commit gives the
# same tools. Get newer versions with update-versions.sh.
variable "runner_version" {
  type        = string
  default     = "2.338.2"
  description = "actions/runner version. A runner that GitHub finds too old updates itself."
}

variable "runner_sha256" {
  type    = string
  default = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"
}

variable "kubectl_version" {
  type    = string
  default = "1.37.2"
}

variable "kubectl_sha256" {
  type    = string
  default = "c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4"
}

variable "helm_version" {
  type        = string
  default     = "3.22.1"
  description = "Helm 3, the same major as the GitHub-hosted image."
}

variable "helm_sha256" {
  type    = string
  default = "896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea"
}

variable "kustomize_version" {
  type    = string
  default = "5.8.3"
}

variable "kustomize_sha256" {
  type    = string
  default = "cb9e31198d3f63b44848bd0afc4c8efc56e6cfef9c93a4a39a211940e6decd61"
}

variable "yq_version" {
  type    = string
  default = "4.54.3"
}

variable "yq_sha256" {
  type    = string
  default = "129534601871538efe0ba4c5e62a34fb1d5f469bcb975c4fddeb467d82974973"
}

locals {
  http_content = {
    "/meta-data" = ""
    "/user-data" = templatefile("${path.root}/http/user-data.pkrtpl.yaml", {
      hostname      = var.vm_name
      username      = var.username
      password_hash = bcrypt(var.build_password)
    })
  }

  # GRUB of the live ISO: start the installer in autoinstall mode.
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud;s=http://${var.http_ip != "" ? var.http_ip : "{{ .HTTPIP }}"}:{{ .HTTPPort }}/\"<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
}

# CI build (Linux with KVM). The workflow converts the qcow2 to VHDX.
source "qemu" "build-vm" {
  vm_name          = "${var.vm_name}.qcow2"
  output_directory = "output"

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  accelerator       = "kvm"
  machine_type      = "q35"
  efi_boot          = true
  efi_firmware_code = var.efi_firmware_code
  efi_firmware_vars = var.efi_firmware_vars
  cpus              = var.cpus
  memory            = var.memory_mb
  headless          = true

  format             = "qcow2"
  disk_size          = "${var.disk_size_gb}G"
  disk_interface     = "virtio"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true
  net_device         = "virtio-net"

  http_content = local.http_content
  boot_wait    = "5s"
  boot_command = local.boot_command

  communicator = "ssh"
  ssh_username = var.username
  ssh_password = var.build_password
  ssh_timeout  = "45m"

  # The autoinstall gives the user sudo without a password (see user-data).
  shutdown_command = "sudo shutdown -P now"
}

# Local build on Windows with Hyper-V (admin, or a member of the group
# Hyper-V Administrators). The VHDX is in output-hyperv/Virtual Hard Disks/.
# The build VM has its own name, so it does not collide with the runner VM
# from BuildVm.ps1. The host name in the image is still var.vm_name.
source "hyperv-iso" "build-vm" {
  vm_name          = "packer-${var.vm_name}"
  output_directory = "output-hyperv"

  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  generation            = 2
  enable_secure_boot    = true
  secure_boot_template  = "MicrosoftUEFICertificateAuthority"
  cpus                  = var.cpus
  memory                = var.memory_mb
  enable_dynamic_memory = false
  switch_name           = var.hyperv_switch

  disk_size       = var.disk_size_gb * 1024
  disk_block_size = 1

  http_content = local.http_content
  boot_wait    = "5s"
  boot_command = local.boot_command

  communicator = "ssh"
  ssh_username = var.username
  ssh_password = var.build_password
  ssh_timeout  = "45m"

  shutdown_command = "sudo shutdown -P now"
}

build {
  sources = ["source.qemu.build-vm", "source.hyperv-iso.build-vm"]

  # The file provisioner below puts the contents of vm/ into this folder,
  # and the folder must exist first.
  provisioner "shell" {
    inline = ["mkdir -p /tmp/vm-files"]
  }

  provisioner "file" {
    source      = "${path.root}/../vm/"
    destination = "/tmp/vm-files"
  }

  provisioner "shell" {
    execute_command = "sudo env {{ .Vars }} bash -eu '{{ .Path }}'"
    environment_vars = [
      "RUNNER_USER=${var.username}",
      "ANDROID_CMDLINE_TOOLS_BUILD=${var.android_cmdline_tools_build}",
      "ANDROID_CMDLINE_TOOLS_SHA256=${var.android_cmdline_tools_sha256}",
      "ANDROID_PACKAGES=${join(" ", var.android_packages)}",
      "NODE_MAJOR=${var.node_major}",
      "RUNNER_VERSION=${var.runner_version}",
      "RUNNER_SHA256=${var.runner_sha256}",
      "KUBECTL_VERSION=${var.kubectl_version}",
      "KUBECTL_SHA256=${var.kubectl_sha256}",
      "HELM_VERSION=${var.helm_version}",
      "HELM_SHA256=${var.helm_sha256}",
      "KUSTOMIZE_VERSION=${var.kustomize_version}",
      "KUSTOMIZE_SHA256=${var.kustomize_sha256}",
      "YQ_VERSION=${var.yq_version}",
      "YQ_SHA256=${var.yq_sha256}",
    ]
    scripts = [
      "${path.root}/scripts/10-base.sh",
      "${path.root}/scripts/15-gh-node.sh",
      "${path.root}/scripts/20-docker.sh",
      "${path.root}/scripts/25-k8s-tools.sh",
      "${path.root}/scripts/30-android-sdk.sh",
      "${path.root}/scripts/40-actions-runner.sh",
      "${path.root}/scripts/90-cleanup.sh",
    ]
  }
}
