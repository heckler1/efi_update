#!/usr/bin/env bash

# This script updates the Clover installation, Clover drivers, and kexts on your EFI partition
# It keeps the config.plist, ACPI folder, and any kexts that it can't download

# Prevent warnings about piping ls to grep
# This is necessary for our usecase
#shellcheck disable=SC2010

# Stop if things start going wrong
set -e

# Declare our functions
logging() {
  echo "${1}" | tee -a "EFI_Update_${today}.log"
}

checkforutil () {
  if ! (command -v "${1}" &> /dev/null)
  then
    logging "The utility ${1} is missing. Please confirm that it is installed, and your \$PATH is correct."
    exit 1
  fi
}

clover_download() {
  # This function downloads the latest ISO tarball for Clover, and extracts it

  # Get the name of the latest Clover ISO
  logging "Getting the URL of the latest Clover..."
  local clover_file
  clover_file=$(curl https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/ 2> /dev/null |  grep -Eo -m 1 "(CloverISO-.....tar.lzma)")
  
  # Download the latest Clover ISO
  logging "Downloading the latest Clover..."
  curl -L "https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/${clover_file}/download" -o "${clover_file}" &> /dev/null
  
  # Get the release number from the tarball's name
  local clover_release
  clover_release=${clover_file#CloverISO-*}
  clover_release=${clover_release%*.tar.lzma}
  logging "Latest Clover is r${clover_release}."

  # Extract the tarball
  logging "Extracting Clover tarball..."
  tar --lzma -xf "${clover_file}" &> /dev/null

  # Delete the tarball
  logging "Deleting the tarball now that we've extracted the ISO..."
  rm "${clover_file}"

  # Set the ISO name, based on the release name
  local iso
  iso=Clover-v2.4k-${clover_release}-X64.iso

  # Mount the ISO
  logging "Mounting the Clover ISO..."
  hdiutil mount "${iso}" &> /dev/null
  
  # Return the volume name
  export clover_source_volume=${iso%*.iso}
}

efi_mount() {
  local boot_disk_name
  boot_disk_name=$(system_profiler SPSoftwareDataType \
    | grep "Boot Volume" \
    | awk -F ":" '{ print $2 }')
  # Get the EFI partition on the primary disk
  local boot_disk_id
  boot_disk_id=$(diskutil list \
    | grep "${boot_disk_name}" \
    | awk '{print $NF}')

  boot_disk_id=${boot_disk_id%s*}

  local efi_disk_id
  efi_disk_id=$(diskutil list \
    | grep "Container ${boot_disk_id}" \
    | awk '{ print $NF}')
  
  efi_disk_id=${efi_disk_id%s*}

  local efi_part_id
  efi_part_id=$(diskutil list \
    | grep "${efi_disk_id}" \
    | grep "EFI" \
    | awk '{ print $NF}')

  if [ "${1}" = "unmount" ]
  then
    logging "Unmounting the EFI partition at ${efi_part_id}..."
    sudo diskutil unmount "${efi_part_id}"
  else
    logging "Mounting the EFI partition at ${efi_part_id}..."
    sudo diskutil mount "${efi_part_id}"
  fi
}

efi_prep() {
  # Backup the current EFI, we need it for reference anyway
  logging "Backing up the current EFI folder..."
  if ! (cp -r /Volumes/EFI/EFI "EFI_Backup_${today}")
  then
    echo "No current EFI folder found, this script needs a working EFI partition for reference."
    exit 1
  fi

  # Clean out the EFI partition for a fresh installation of Clover
  logging "Cleaning out EFI partition..."
  rm -rf /Volumes/EFI/EFI
}

clover_prep() {
  # Build out a Clover skeleton
  logging "Creating fresh Clover installation..."
  mkdir -p /Volumes/EFI/EFI/BOOT /Volumes/EFI/EFI/CLOVER/kexts/Other /Volumes/EFI/EFI/CLOVER/drivers64UEFI
  cp -r /Volumes/${1}/EFI/BOOT/* /Volumes/EFI/EFI/BOOT
  cp -r "/Volumes/${1}/EFI/CLOVER/tools" /Volumes/EFI/EFI/CLOVER/
  cp "/Volumes/${1}/EFI/CLOVER/CLOVERX64.efi" /Volumes/EFI/EFI/CLOVER/
}

install_kext () {
  # This function takes a kext name, and install the latest version of it it to the EFI
  # Pretty much only works for acidanthera's kexts right now, but let's be honest, that's pretty much all the important ones

  # If there are some options
  case "${1}" in
    AppleALC|Lilu|WhateverGreen|VirtualSMC|AirportBrcmFixup)
      local reponame
      reponame=${1}
      
      logging "Getting download URL for ${reponame}..."
      # Use the GitHub API to get the link to the latest release of the given repo
      local url
      url=https://api.github.com/repos/acidanthera/${reponame}/releases/latest
      url=$(curl "${url}" 2> /dev/null \
        | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["assets"][1]["browser_download_url"]')

      # Download the kext
      get_zip "${url}" "${reponame}"

      logging "Installing ${reponame}.kext..."
      # Get the path to the kext
      local kext_path
      kext_path=$(find "${reponame}" -name "${reponame}.kext")

      # Put the kext in the EFI partition
      cp -r "${kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      
      # Make a few special provisions for VirtualSMC
      if [ "${1}" = "VirtualSMC" ]
      then
        logging "Installing VirtualSmc.efi..."
        # Update the EFI driver
        local driver_path
        driver_path=$(find "${reponame}" -name VirtualSmc.efi)
        cp "${driver_path}" /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
        
        # Update our SMC sensor kexts
        for smc_kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -E "(^SMC)")
        do
          logging "Installing ${smc_kext}..."
          local smc_kext_path
          smc_kext_path=$(find "${reponame}" -name "${smc_kext}")
          cp -r "${smc_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
        done
      fi

      logging "Deleting leftover files..."
      # Cleanup
      rm -rf "${reponame}"
      ;;
    VoodooI2C)
      local reponame
      reponame=${1}
      
      logging "Getting download URL for $reponame..."
      # Use the GitHub API to get the link to the latest release of the given repo
      local url
      url=https://api.github.com/repos/alexandred/${reponame}/releases/latest
      url=$(curl "${url}" 2> /dev/null \
        | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["assets"][1]["browser_download_url"]')
      
      # Download the kext
      get_zip "${url}" "${reponame}"

      logging "Installing ${reponame}.kext..."
      # Get the path to the kext
      local kext_path
      kext_path=$(find "${reponame}" -name "${reponame}.kext")
      # Put the kext in the EFI partition
      cp -r "${kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/

      for i2c_kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -E "VoodooI2C[A-Z]")
      do
        logging "Installing ${i2c_kext}..."
        local i2c_kext_path
        i2c_kext_path=$(find "${reponame}" -name "${i2c_kext}")
        cp -r "${i2c_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      done

      logging "Deleting leftover files..."
      # Cleanup
      rm -rf "${reponame}"
      ;;
    RealtekRTL8111|IntelMausiEthernet|VoodooPS2Controller)
      local reponame
      reponame=${1}

      logging "Getting download URL for ${reponame}..."
      case "${1}" in
        RealtekRTL8111)
        local url
        url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-realtek-network/downloads
        ;;
        IntelMausiEthernet)
        local url
        url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-intel-network/downloads
        ;;
        VoodooPS2Controller)
        local url
        url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-voodoo-ps2-controller/downloads
        ;;
      esac

      # Use the BitBucket API to get the download link of the latest release
      local url
      url=$(curl "${url}" 2> /dev/null | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["values"][0]["links"]["self"]["href"]')
      
      # Download the kext
      get_zip "${url}" "${reponame}"

      logging "Installing ${reponame}.kext..."
      # Put the kext in the EFI partition
      cp -r "${reponame}/Release/${reponame}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/

      logging "Deleting leftover files..."
      # Cleanup
      rm -rf "${reponame}"
      ;;
    FakePCIID)
      local reponame
      reponame=${1}

      logging "Getting download URL for ${reponame}..."
      local url
      url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-fake-pci-id/downloads
      # Use the BitBucket API to get the download link of the latest release
      url=$(curl "${url}" 2> /dev/null \
        | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["values"][0]["links"]["self"]["href"]')
      
      # Download the kext
      get_zip "${url}" "${reponame}"

      logging "Installing ${reponame}.kext..."
      # Put the kext in the EFI partition
      cp -r "${reponame}/Release/${reponame}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      
      for fakepci_kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -E "FakePCIID_[A-Z]")
      do
        logging "Installing ${fakepci_kext}..."
        local fakepci_kext_path
        fakepci_kext_path=$(find "${reponame}" -name "${fakepci_kext}")
        cp -r "${fakepci_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      done
      
      logging "Deleting leftover files..."
      # Cleanup
      rm -rf "${reponame}"
      ;;
    BrcmPatchRAM*)
      local reponame
      reponame=${1}

      logging "Getting download URL for ${reponame}..."
      local url
      url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-brcmpatchram/downloads
      # Use the BitBucket API to get the download link of the latest release
      url=$(curl "${url}" 2> /dev/null \
        | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["values"][0]["links"]["self"]["href"]')
      
      # Download the kext
      get_zip "${url}" "${reponame}"

      logging "Installing ${reponame}.kext..."
      # Put the kext in the EFI partition
      cp -r "${reponame}/Release/${reponame}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/

      for brcm_kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -E "BrcmFirmware[A-Z]" | grep -v "${reponame}.kext")
      do
        logging "Installing ${brcm_kext}..."
        local brcm_kext_path
        brcm_kext_path=$(find "${reponame}" -name "${brcm_kext}")
        cp -r "${brcm_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      done
      
      logging "Deleting leftover files..."
      # Cleanup
      rm -rf "${reponame}"
      ;;
    *)
      logging "I don't know how to download ${1}.kext"
      logging "Copying ${1}.kext from the EFI backup..."
      cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${1}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      ;;
    esac
}

get_zip() {
  # This function downloads a zip file, and extracts it
  local url
  url=${1}
  local reponame
  reponame=${2}

  # Download it
  logging "Downloading ${reponame}..."
  curl -OJL "${url}" &> /dev/null

  # Get the name of the file we downloaded
  local zip_name
  zip_name=${url##*'/'}

  # Extract the archive
  logging "Unzipping ${zip_name}..."
  unzip "${zip_name}" -d "${reponame}" &> /dev/null

  # Post-extraction cleanup
  rm "${zip_name}"
}

clover_configure(){
  clover_prep "${1}"

  # Copy over our config.plist
  logging "Copying config.plist from the EFI backup..."
  cp "EFI_Backup_${today}/CLOVER/config.plist" /Volumes/EFI/EFI/CLOVER/

  # Get the latest drivers
  # HFSPlus.efi is skipped because it doesn't change, though we could sum the one on GitHub against the current one
  # VirtualSMC.efi is in the VirtualSMC release package, so it is updated when VirtualSMC.kext is updated
  logging "Installing latest Clover drivers..."
  for drivername in $(ls "EFI_Backup_${today}/CLOVER/drivers64UEFI" | grep -v HFSPlus.efi | grep -v VirtualSmc.efi)
  do
    logging "Installing ${drivername}..."
    local driver_path
    driver_path=$(find -f /Volumes/${1}/EFI/CLOVER/drivers* -name "${drivername}" \
      | grep "UEFI")
    cp "${driver_path}" /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
  done

  # Bring HFSPlus.efi over from the backup
  logging "Copying HFSPlus.efi from the EFI backup..."
  
  if [ -f "EFI_Backup_${today}/CLOVER/drivers64UEFI/HFSPlus.efi" ]
  then
    cp "EFI_Backup_${today}/CLOVER/drivers64UEFI/HFSPlus.efi" /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
  else
    echo "No HFSPlus.efi found in the old Clover folder, skipping..."
  fi
  
  # If there is an ACPI folder, bring it over from the backup
  # This makes sure our DSDTs and SSDTs are there
  if [ -d "EFI_Backup_${today}/CLOVER/ACPI" ]
  then
    logging "Copying DSDTs/SSDTs from the EFI backup..."
    cp -r "EFI_Backup_${today}/CLOVER/ACPI" /Volumes/EFI/EFI/CLOVER/
  fi

  # Get the latest versions of all our kexts
  # SMC sensor kexts are accounted for in the VirtualSMC kext update
  # The extra I2C kexts are accounted for in the VoodooI2C kext update
  for kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -vE "(^SMC)" | grep -vE "VoodooI2C[A-Z]" | grep -vE "FakePCIID_[A-Z]" |  grep -vE "BrcmFirmware[A-Z]")
  do
    install_kext "${kext%*.kext}"
  done
}

# Now run it all
today=$(date +%Y_%m_%d)
mkdir "EFI_Update_${today}"
cd "EFI_Update_${today}"
clover_download
efi_mount
efi_prep
clover_configure "${clover_source_volume}"
logging "Unmounting Clover ISO..."
diskutil unmount "${clover_source_volume}" &> /dev/null
logging "Deleting Clover ISO..."
rm "${clover_source_volume}.iso"
logging "Update complete."
mv "EFI_Update_${today}.log" /Volumes/EFI/EFI/
efi_mount unmount