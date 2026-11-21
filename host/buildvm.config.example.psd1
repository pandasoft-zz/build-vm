# Config of host/BuildVm.ps1. Copy it to buildvm.config.psd1 (in .gitignore)
# to change values; without that copy the script uses this file.
@{
    # Hyper-V VM.
    VmName     = 'build-vm'
    Cpus       = 4
    MemoryGB   = 8
    DiskGB     = 80               # the image disk grows to this size on first boot
    SwitchName = 'Default Switch' # the VM needs internet access
    VmRoot     = ''               # empty: the Hyper-V default folder for VMs

    # Image releases.
    ImageRepo  = 'pandasoft-zz/build-vm'

    # Runner label, and the value of the RUNNER variable in the repositories.
    Label      = 'build-vm'

    # Runners for each repository. A runner runs one job at a time; with 2 or
    # more, jobs of one repository run in parallel (each runner has its own
    # folder and HOME). Give the VM enough CPUs and RAM for the parallel jobs.
    RunnersPerRepo = 1

    # Repositories for Register, Unregister, Enable, Disable and Status.
    # Put your own list in buildvm.config.psd1 (not committed), for example:
    #   Repos = @('owner/repo-a', 'owner/repo-b')
    Repos      = @()
}
