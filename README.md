# EFI_Update.sh
This script updates an existing Clover bootloader installation. It assumes that you have a [vanilla](https://hackintosh.gitbook.io/-r-hackintosh-vanilla-desktop-guide/) Clover install already set up and working. The script does the following things:
* Backs up your EFI folder
* Creates a new EFI folder with the latest version of Clover
* Updates your .efi drivers with ones from the latest version of Clover
    * Also updates VirtualSmc.efi, if installed
    * Does not support FakeSMC at this time
* Updates your kexts
    * Any unsupported kexts are copied from the EFI backup

The script preserves any files in the ACPI folder, as well as your config.plist.

## Supported Kexts
Due to each kext developer packaging their releases differently, most kexts have to have support added individually. Currently the following kexts are supported:
* AppleALC
* BrcmPatchRAM(2)
    * Also updates BrcmFirmwareRepo.kext or BrcmFirmwareData.kext
    * Does not support BrcmNonPatchRAM(2) at this time
* FakePCIID
    * Also updates the specific FakePCI kext you are using, such as FakePCIID_Broadcom_WiFi.kext
* IntelMausiEthernet
* Lilu
* RealtekRT8111
* WhateverGreen
* VirtualSMC
    * Also updates VirtualSmc.efi, and any SMC sensor kexts, such as SMCProcessor.kext
* VoodooI2C
    * Also updates the I2C kext for your specific trackpad model, such as VoodooI2CFTE.kext
* VoodooPS2Controller
