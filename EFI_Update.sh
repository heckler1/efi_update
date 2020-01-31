#!/usr/bin/env bash

# This script updates the Clover installation, Clover drivers, and kexts on your EFI partition
# It keeps the config.plist, ACPI folder, and any kexts that it can't download

# Prevent warnings about piping ls to grep
# This is necessary for our usecase
#shellcheck disable=SC2010

# Declare our functions
logging() {
  # Print to stdout, but also a log file
  echo "${@}" | tee -a "EFI_Update_${today}.log"
}

sudo_check() {
  # Ensure we have root privileges
  if [ "$(whoami)" != "root" ]
  then
    logging "Please run this script with sudo. Exiting..."
    exit 1
  fi
}

checkforutil () {
  # Check if the given utility is available
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
  clover_file=$(curl https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/ 2> /dev/null \
    |  grep -Eo -m 1 "(CloverISO-.....tar.lzma)")
  
  # Ensure we have a file name
  if [ -z "${clover_file}" ]
  then
    logging "Unable to determine the latest Clover version. Exiting..."
    exit 1
  fi

  # Download the latest Clover ISO
  logging "Downloading the latest Clover..."
  if ! (curl -L "https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/${clover_file}/download" -o "${clover_file}" &> /dev/null)
  then
    logging "Failed to download the Clover ISO. Exiting..."
    exit 1
  fi
  
  # Get the release number from the tarball's name
  local clover_release
  clover_release=${clover_file#CloverISO-*}
  clover_release=${clover_release%*.tar.lzma}

  # Validate the release number
  if [[ ${clover_release} =~ [0-9]{4,} ]]
  then
    logging "Latest Clover is r${clover_release}."
  else
    logging "Unable to determine Clover release number. Exiting..."
    exit 1
  fi

  # Extract the tarball
  logging "Extracting Clover tarball..."
  if ! (tar --lzma -xf "${clover_file}" &> /dev/null)
  then
    logging "Extracting Clover tarball failed. Exiting..."
    exit 1
  fi

  # Delete the tarball
  logging "Deleting the tarball, now that we've extracted the ISO..."
  if ! (rm "${clover_file}")
  then
    logging "Deleting Clover tarball failed. Exiting..."
    exit 1
  fi

  # Set the ISO name, based on the release name
  local iso
  iso=$(ls \
    | grep "${clover_release}" \
    | grep -v "tar.lzma")

  # Mount the ISO
  logging "Mounting the Clover ISO..."
  if ! (hdiutil mount "${iso}" &> /dev/null)
  then
    logging "Mounting Clover ISO failed. Exiting..."
  fi
  
  # Return the volume name
  export clover_source_volume=${iso%*.iso}
}

efi_mount() {
  # Get the name of the currently booted partition
  local boot_disk_name
  boot_disk_name=$(system_profiler SPSoftwareDataType \
    | grep "Boot Volume" \
    | awk -F ":" '{ print $2 }')

  # Get the ID (diskXsX) of the currently booted partition
  local boot_disk_id
  boot_disk_id=$(diskutil list \
    | grep "${boot_disk_name}" \
    | grep -v -- "- Data" \
    | awk '{print $NF}')

  # Get the ID (diskX) of the current boot disk - This is actually an APFS container, stored in a partition on a physical disk
  boot_disk_id=${boot_disk_id%s*}

  # Get the ID (diskXsX) of the partition that has the APFS container of the boot disk
  local efi_disk_id
  efi_disk_id=$(diskutil list \
    | grep "Container ${boot_disk_id}" \
    | awk '{ print $NF}')
  
  # Get the disk ID (diskX) of the disk, with the partition, with the APFS container
  # This is important because the EFI partition is on the physical disk, not inside the APFS container
  efi_disk_id=${efi_disk_id%s*}

  # Now find the EFI partition on the physical disk
  local efi_part_id
  efi_part_id=$(diskutil list \
    | grep "${efi_disk_id}" \
    | grep "EFI" \
    | awk '{ print $NF}')

  # Validate the result
  # This regex does exactly what I want
  #shellcheck disable=SC2140
  if ! [[ ${efi_part_id} =~ "disk"."s". ]]
  then
    logging "Unable to determine the current EFI partition. Exiting..."
    exit 1
  fi

  # Mount or unmount the EFI partition, depending on the command
  if [ "${1}" = "unmount" ]
  then
    logging "Unmounting the EFI partition at ${efi_part_id}..."
    if ! (diskutil unmount "${efi_part_id}")
    then
      logging "Failed to unmount EFI partition. Exiting..."
      exit 1
    fi
  else
    logging "Mounting the EFI partition at ${efi_part_id}..."
    if ! (diskutil mount "${efi_part_id}")
    then
      logging "Failed to mount EFI partition. Exiting..."
      exit 1
    fi
  fi
}

efi_prep() {
  # Backup the current EFI, we need it for reference anyway
  logging "Backing up the current EFI folder..."
  if ! (cp -r /Volumes/EFI/EFI "EFI_Backup_${today}")
  then
    logging "No current EFI folder found, this script needs a working EFI partition for reference."
    exit 1
  fi

  # Clean out the EFI partition for a fresh installation of Clover
  logging "Cleaning out EFI partition..."
  if ! (rm -rf /Volumes/EFI/EFI)
  then
    logging "Failed to delete the old EFI partition. Exiting..."
    exit 1
  fi
}

clover_prep() {
  # Build out a Clover skeleton
  logging "Creating fresh Clover installation..."

  # Create the directory structure
  if ! (mkdir -p /Volumes/EFI/EFI/BOOT /Volumes/EFI/EFI/CLOVER/kexts/Other /Volumes/EFI/EFI/CLOVER/drivers/UEFI)
  then
    logging "Prepping new Clover install failed. Exiting..."
    exit 1
  fi

  # Install the base bootloader
  if ! (cp -r /Volumes/${1}/EFI/BOOT/* /Volumes/EFI/EFI/BOOT)
  then
    logging "Prepping new Clover install failed. Exiting..."
    exit 1
  fi
  if ! (cp -r "/Volumes/${1}/EFI/CLOVER/tools" /Volumes/EFI/EFI/CLOVER/)
  then
    logging "Prepping new Clover install failed. Exiting..."
    exit 1
  fi
  if ! (cp "/Volumes/${1}/EFI/CLOVER/CLOVERX64.efi" /Volumes/EFI/EFI/CLOVER/)
  then
    logging "Prepping new Clover install failed. Exiting..."
    exit 1
  fi
}

install_kext () {
  # This function takes a kext name, and install the latest version of it it to the EFI
  # This only supports a limited number of kexts, but it is most of the common ones

  # Get the argument
  case "${1}" in
    # All of acidanthera's kexts can be updated the same way
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

      # If downloading or extracting the kext failed in anyway, fail safe and grab the old one from the backup
      if [ ${?} -ne 0 ]
      then
        logging "Unable to get ${1}."
        logging "Copying ${1}.kext from the EFI backup..."
        cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${1}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      fi

      # Put the kext in the EFI partition
      cp -r "${kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      
      # Make a few special provisions for VirtualSMC
      if [ "${1}" = "VirtualSMC" ]
      then
        logging "Installing VirtualSmc.efi..."
        # Update the EFI driver
        local driver_path
        driver_path=$(find "${reponame}" -name VirtualSmc.efi)
        cp "${driver_path}" /Volumes/EFI/EFI/CLOVER/drivers/UEFI/
        
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

      # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
      if [ ${?} -ne 0 ]
      then
        logging "Unable to get ${1}."
        logging "Copying ${1}.kext from the EFI backup..."
        cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${1}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      else
        # Otherwise, just put the new kext in the EFI partition
        cp -r "${kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      fi

      for i2c_kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -E "VoodooI2C[A-Z]")
      do
        logging "Installing ${i2c_kext}..."
        local i2c_kext_path
        i2c_kext_path=$(find "${reponame}" -name "${i2c_kext}")

        # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
        if [ ${?} -ne 0 ]
        then
          logging "Copying ${i2c_kext} from the EFI backup..."
          cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${i2c_kext}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
        else
          cp -r "${i2c_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
        fi
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

      # Get the path to the kext
      local kext_path
      kext_path=$(find "${reponame}" -name "${reponame}.kext" | grep "Release")

      # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
      if [ ${?} -ne 0 ]
      then
        logging "Unable to get ${1}."
        logging "Copying ${1}.kext from the EFI backup..."
        cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${1}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      else
        # Otherwise, just put the new kext in the EFI partition
        cp -r "${kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      fi

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

      # Get the path to the kext
      local kext_path
      kext_path=$(find "${reponame}" -name "${reponame}.kext")

      # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
      if [ ${?} -ne 0 ]
      then
        logging "Unable to get ${1}."
        logging "Copying ${1}.kext from the EFI backup..."
        cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${1}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      else
        # Otherwise, just put the new kext in the EFI partition
        cp -r "${kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      fi

      for fakepci_kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -E "FakePCIID_[A-Z]")
      do
        logging "Installing ${fakepci_kext}..."
        local fakepci_kext_path
        fakepci_kext_path=$(find "${reponame}" -name "${fakepci_kext}")

        # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
        if [ ${?} -ne 0 ]
        then
          logging "Copying ${fakepci_kext} from the EFI backup..."
          cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${fakepci_kext}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
        else
          cp -r "${fakepci_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
        fi
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

      # Get the path to the kext
      local kext_path
      kext_path=$(find "${reponame}" -name "${reponame}.kext")

      # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
      if [ ${?} -ne 0 ]
      then
        logging "Unable to get ${1}."
        logging "Copying ${1}.kext from the EFI backup..."
        cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${1}.kext" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      else
        # Otherwise, just put the new kext in the EFI partition
        cp -r "${kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
      fi
      
      for brcm_kext in $(ls "EFI_Backup_${today}/CLOVER/kexts/Other/" | grep -E "BrcmFirmware[A-Z]" | grep -v "${reponame}.kext")
      do
        logging "Installing ${brcm_kext}..."
        local brcm_kext_path
        brcm_kext_path=$(find "${reponame}" -name "${brcm_kext}")
        # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
        if [ ${?} -ne 0 ]
        then
          logging "Copying ${brcm_kext_path} from the EFI backup..."
          cp -r "EFI_Backup_${today}/CLOVER/kexts/Other/${brcm_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
        else
          cp -r "${brcm_kext_path}" /Volumes/EFI/EFI/CLOVER/kexts/Other/
        fi
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
  if ! (curl -OJL "${url}" &> /dev/null)
  then
    logging "Downloading ${reponame} failed..."
    return 1
  fi

  # Get the name of the file we downloaded
  local zip_name
  zip_name=${url##*'/'}

  # Extract the archive
  logging "Unzipping ${zip_name}..."
  if ! (unzip "${zip_name}" -d "${reponame}" &> /dev/null)
  then
    logging "Extracting ${reponame} failed..."
    return 1
  fi

  # Post-extraction cleanup
  if ! (rm "${zip_name}")
  then
    logging "Deleting ${zip_name} failed..."
    return 1
  fi
}

clover_configure(){
  clover_prep "${1}"

  # Copy over our config.plist
  logging "Copying config.plist from the EFI backup..."
  if ! (cp "EFI_Backup_${today}/CLOVER/config.plist" /Volumes/EFI/EFI/CLOVER/)
  then
    logging "Copying config.plist from the backup failed. Exiting..."
    exit 1
  fi

  # Get the latest drivers
  # HFSPlus.efi is skipped because it doesn't change, though we could sum the one on GitHub against the current one
  # VirtualSMC.efi is in the VirtualSMC release package, so it is updated when VirtualSMC.kext is updated
  logging "Installing latest Clover drivers..."
  for drivername in $(ls "EFI_Backup_${today}/CLOVER/drivers/UEFI" | grep -v HFSPlus.efi | grep -v VirtualSmc.efi)
  do
    logging "Installing ${drivername}..."
    local driver_path
    driver_path=$(find /Volumes/${1}/EFI/CLOVER/drivers* -name "${drivername}" \
      | grep "off")

    # If downloading or extracting the kext failed in any way, fail safe and grab the old one from the backup
    if [ ${?} -ne 0 ]
    then
      logging "Unable to get ${drivername} from the Clover ISO..."
      logging "Copying ${drivername} from the EFI backup..."
      cp -r "EFI_Backup_${today}/CLOVER/drivers/UEFI/${drivername}" /Volumes/EFI/EFI/CLOVER/drivers/UEFI/
    else
      cp "${driver_path}" /Volumes/EFI/EFI/CLOVER/drivers/UEFI/
    fi
  done

  # Bring HFSPlus.efi over from the backup
  logging "Copying HFSPlus.efi from the EFI backup..."
  
  if [ -f "EFI_Backup_${today}/CLOVER/drivers/UEFI/HFSPlus.efi" ]
  then
    cp "EFI_Backup_${today}/CLOVER/drivers/UEFI/HFSPlus.efi" /Volumes/EFI/EFI/CLOVER/drivers/UEFI/
  else
    logging "No HFSPlus.efi found in the old Clover folder, skipping..."
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
sudo_check
today=$(date +%Y_%m_%d)
mkdir "EFI_Update_${today}"
cd "EFI_Update_${today}" || (logging "Failed to move into EFI_Update directory. Exiting..."; exit 1)
clover_download
efi_mount
efi_prep
clover_configure "${clover_source_volume}"
logging "Unmounting Clover ISO..."
diskutil unmount "${clover_source_volume}" &> /dev/null
logging "Deleting Clover ISO..."
rm "${clover_source_volume}.iso"
logging "Update complete."
cp "EFI_Update_${today}.log" /Volumes/EFI/EFI/
efi_mount unmount