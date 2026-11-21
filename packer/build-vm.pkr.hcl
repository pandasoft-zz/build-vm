packer {
  required_version = ">= 1.11.0"
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

# The image is built with QEMU/KVM on a Linux CI runner and then converted to
# a Hyper-V VHDX (see .github/workflows/image.yml). The image holds no secret:
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

variable "disk_size" {
  type        = string
  default     = "40G"
  description = "Size of the image disk. BuildVm.ps1 can make the VM disk bigger; cloud-init then grows the partition."
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

variable "runner_version" {
  type        = string
  default     = "latest"
  description = "actions/runner version without the 'v' (for example 2.330.0), or 'latest'."
}

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
  disk_size          = var.disk_size
  disk_interface     = "virtio"
  disk_discard       = "unmap"
  disk_detect_zeroes = "unmap"
  disk_compression   = true
  net_device         = "virtio-net"

  http_content = {
    "/meta-data" = ""
    "/user-data" = templatefile("${path.root}/http/user-data.pkrtpl.yaml", {
      hostname      = var.vm_name
      username      = var.username
      password_hash = bcrypt(var.build_password)
    })
  }

  # GRUB of the live ISO: start the installer in autoinstall mode.
  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=\"nocloud;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/\"<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  communicator = "ssh"
  ssh_username = var.username
  ssh_password = var.build_password
  ssh_timeout  = "45m"

  # The autoinstall gives the user sudo without a password (see user-data).
  shutdown_command = "sudo shutdown -P now"
}

build {
  sources = ["source.qemu.build-vm"]

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
    ]
    scripts = [
      "${path.root}/scripts/10-base.sh",
      "${path.root}/scripts/15-gh-node.sh",
      "${path.root}/scripts/20-docker.sh",
      "${path.root}/scripts/30-android-sdk.sh",
      "${path.root}/scripts/40-actions-runner.sh",
      "${path.root}/scripts/90-cleanup.sh",
    ]
  }
}
