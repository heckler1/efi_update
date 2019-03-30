# This script updates the Clover installation, Clover drivers, and kexts on your EFI partition
# It keeps the config.plist, ACPI folder, and any kexts that it can't download 

# Stop if things start going wrong
set -e

# Declare our functions
logging() {
  echo $1 | tee -a EFI_Update_$today.log
}

checkforutil () {
  command -v ${1} &> /dev/null
  if [[ ${?} != 0 ]]
  then
    logging "The utility ${1} is missing. Please confirm that it is installed, and your \$PATH is correct."
    exit 1
  fi
}

clover_download() {
  ###
  # CODE TO DOWNLOAD THE ISO
  ###

  # Get the name of the latest Clover ISO
  logging "Getting the URL of the latest Clover..."
  cloverfile=$(curl https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/ 2> /dev/null |  grep -Eo -m 1 "(CloverISO-.....tar.lzma)")
  
  # Download the latest Clover ISO
  logging "Downloading the latest Clover..."
  curl -L https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/$cloverfile/download -o $cloverfile &> /dev/null
  
  # Get the release number from the tarball's name
  cloverrelease=${cloverfile#CloverISO-*}
  cloverrelease=${cloverrelease%*.tar.lzma}
  logging "Latest Clover is r$cloverrelease."

  # Extract the tarball
  logging "Extracting Clover tarball..."
  tar --lzma -xf $cloverfile &> /dev/null

  # Delete the tarball
  logging "Deleting the tarball now that we've extracted the ISO..."
  rm $cloverfile

  # Set the ISO name, based on the release name
  iso=Clover-v2.4k-$cloverrelease-X64.iso

  # Mount the ISO
  logging "Mounting the Clover ISO..."
  hdiutil mount $iso &> /dev/null
  
  # Return the volume name
  export clover_source_volume=${iso%*.iso}
  ###
  # CODE TO DOWNLOAD THE ZIP
  # UNUSED
  ###
  # Get latest Clover zip
  #curloutput=$(curl https://sourceforge.net/projects/cloverefiboot/files/latest/download -o latest_clover.zip 2>&1)

  # Match regex for Clover zip file name
  #clovername=$(echo $curloutput | grep -Eo -m 1 "(Clover_v2.4k_r.....zip)")
  # Rename the downloaded file
  #mv latest_clover.zip $clovername
  # Unzip the file
  #unzip $clovername
}

efi_mount() {
  boot_disk_name=$(system_profiler SPSoftwareDataType \
  | grep "Boot Volume" \
  | awk -F ":" '{ print $2 }')
  # Get the EFI partition on the primary disk
  boot_disk_id=$(diskutil list | grep "${boot_disk_name}" | awk '{print $NF}')

  boot_disk_id=${boot_disk_id%s*}

  efi_disk_id=$(diskutil list | grep "Container ${boot_disk_id}" | awk '{ print $NF}')
  
  efi_disk_id=${efi_disk_id%s*}

  efi_part_id=$(diskutil list | grep "${efi_disk_id}" | grep "EFI" | awk '{ print $NF}')
  # Mount it
  logging "Mounting the EFI partition at ${efi_part_id}..."
  sudo diskutil mount $efi_part_id
}

efi_prep() {
  # Backup the current EFI, we need it for reference anyway
  logging "Backing up the current EFI folder..."
  cp -r /Volumes/EFI/EFI EFI_Backup_$today

  # Clean out the EFI partition for a fresh installation of Clover
  logging "Cleaning out EFI partition..."
  rm -rf /Volumes/EFI/EFI
}

clover_prep() {
  # Build out a Clover skeleton
  logging "Creating fresh Clover installation..."
  mkdir -p /Volumes/EFI/EFI/BOOT /Volumes/EFI/EFI/CLOVER/kexts/Other /Volumes/EFI/EFI/CLOVER/drivers64UEFI
  cp -r /Volumes/$1/EFI/BOOT/* /Volumes/EFI/EFI/BOOT
  cp -r /Volumes/$1/EFI/CLOVER/tools /Volumes/EFI/EFI/CLOVER/
  cp /Volumes/$1/EFI/CLOVER/CLOVERX64.efi /Volumes/EFI/EFI/CLOVER/
}

install_kext () {
  # This function takes a kext name, and install the latest version of it it to the EFI
  # Pretty much only works for acidanthera's kexts right now, but let's be honest, that's pretty much all the important ones

  # If there are some options
  case "${1}" in
    AppleALC|Lilu|WhateverGreen|VirtualSMC)
      reponame=$1
      
      logging "Getting download URL for $reponame..."
      # Use the GitHub API to get the link to the latest release of the given repo
      url=https://api.github.com/repos/acidanthera/$1/releases/latest
      url=$(curl $url 2> /dev/null | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["assets"][1]["browser_download_url"]')

      # Download the kext
      get_zip $url $reponame

      logging "Installing $reponame.kext..."
      # Get the path to the kext
      kext_path=$(find $reponame -name $reponame.kext)
      # Put the kext in the EFI partition
      cp -r $kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/
      
      # Make a few special provisions for VirtualSMC
      if [ $1 = "VirtualSMC" ]
      then
        logging "Installing VirtualSmc.efi..."
        # Update the EFI driver
        driver_path=$(find $reponame -name VirtualSmc.efi)
        cp $driver_path /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
        
        # Update our SMC sensor kexts
        for smc_kext in $(ls EFI_Backup_$today/CLOVER/kexts/Other/ | grep -E "(^SMC)")
        do
          logging "Installing $smc_kext..."
          smc_kext_path=$(find $reponame -name $smc_kext)
          cp -r $smc_kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/
        done
      fi

      logging "Deleting leftover files..."
      # Cleanup
      rm -rf $reponame
      ;;
    VoodooI2C)
      reponame=$1
      
      logging "Getting download URL for $reponame..."
      # Use the GitHub API to get the link to the latest release of the given repo
      url=https://api.github.com/repos/alexandred/$1/releases/latest
      url=$(curl $url 2> /dev/null | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["assets"][1]["browser_download_url"]')
      
      # Download the kext
      get_zip $url $reponame

      logging "Installing $reponame.kext..."
      # Get the path to the kext
      kext_path=$(find $reponame -name $reponame.kext)
      # Put the kext in the EFI partition
      cp -r $kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/

      for i2c_kext in $(ls EFI_Backup_$today/CLOVER/kexts/Other/ | grep -E "VoodooI2C[A-Z]")
      do
        logging "Installing $i2c_kext..."
        i2c_kext_path=$(find $reponame -name $i2c_kext)
        cp -r $i2c_kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/
      done

      logging "Deleting leftover files..."
      # Cleanup
      rm -rf $reponame
      ;;
    RealtekRTL8111|IntelMausiEthernet|VoodooPS2Controller)
      reponame=$1

      logging "Getting download URL for $reponame..."
      case "${1}" in
        RealtekRTL8111)
        url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-realtek-network/downloads
        ;;
        IntelMausiEthernet)
        url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-intel-network/downloads
        ;;
        VoodooPS2Controller)
        url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-voodoo-ps2-controller/downloads
        ;;
      esac

      # Use the BitBucket API to get the download link of the latest release
      url=$(curl $url 2> /dev/null | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["values"][0]["links"]["self"]["href"]')
      
      # Download the kext
      get_zip $url $reponame

      logging "Installing $reponame.kext..."
      # Put the kext in the EFI partition
      cp -r $reponame/Release/$reponame.kext /Volumes/EFI/EFI/CLOVER/kexts/Other/

      logging "Deleting leftover files..."
      # Cleanup
      rm -rf $reponame
      ;;
    FakePCIID)
      reponame=$1

      logging "Getting download URL for $reponame..."
      url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-fake-pci-id/downloads
      # Use the BitBucket API to get the download link of the latest release
      url=$(curl $url 2> /dev/null | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["values"][0]["links"]["self"]["href"]')
      
      # Download the kext
      get_zip $url $reponame

      logging "Installing $reponame.kext..."
      # Put the kext in the EFI partition
      cp -r $reponame/Release/$reponame.kext /Volumes/EFI/EFI/CLOVER/kexts/Other/
      
      for fakepci_kext in $(ls EFI_Backup_$today/CLOVER/kexts/Other/ | grep -E "FakePCIID_[A-Z]")
      do
        logging "Installing $fakepci_kext..."
        fakepci_kext_path=$(find $reponame -name $fakepci_kext)
        cp -r $fakepci_kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/
      done
      
      logging "Deleting leftover files..."
      # Cleanup
      rm -rf $reponame
      ;;
    BrcmPatchRAM*)
      reponame=$1

      logging "Getting download URL for $reponame..."
      url=https://api.bitbucket.org/2.0/repositories/RehabMan/os-x-brcmpatchram/downloads
      # Use the BitBucket API to get the download link of the latest release
      url=$(curl $url 2> /dev/null | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["values"][0]["links"]["self"]["href"]')
      
      # Download the kext
      get_zip $url $reponame

      logging "Installing $reponame.kext..."
      # Put the kext in the EFI partition
      cp -r $reponame/Release/$reponame.kext /Volumes/EFI/EFI/CLOVER/kexts/Other/

      for brcm_kext in $(ls EFI_Backup_$today/CLOVER/kexts/Other/ | grep -E "BrcmFirmware[A-Z]" | grep -v $reponame.kext)
      do
        logging "Installing $brcm_kext..."
        brcm_kext_path=$(find $reponame -name $brcm_kext)
        cp -r $brcm_kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/
      done
      
      logging "Deleting leftover files..."
      # Cleanup
      rm -rf $reponame
      ;;
    *)
      logging "I don't know how to download ${1}.kext"
      logging "Copying ${1}.kext from the EFI backup..."
      cp -r EFI_Backup_$today/CLOVER/kexts/Other/${1}.kext /Volumes/EFI/EFI/CLOVER/kexts/Other/
      ;;
    esac
}

get_zip() {
  # This function downloads a zip file, and extracts it
  url=$1
  reponame=$2
  # Download it
  logging "Downloading $reponame..."
  curl -OJ $url &> /dev/null

  # Get the name of the file we downloaded
  zip_name=${url##*'/'}

  # Extract the archive
  logging "Unzipping $zip_name..."
  unzip $zip_name -d $reponame &> /dev/null

  # Post-extraction cleanup
  rm $zip_name
}

clover_configure(){
  clover_prep $1

  # Copy over our config.plist
  logging "Copying config.plist from the EFI backup..."
  cp EFI_Backup_$today/CLOVER/config.plist /Volumes/EFI/EFI/CLOVER/

  # Get the latest drivers
  # HFSPlus.efi is skipped because it doesn't change, though we could sum the one on GitHub against the current one
  # VirtualSMC.efi is in the VirtualSMC release package, so it is updated when VirtualSMC.kext is updated
  logging "Installing latest Clover drivers..."
  for drivername in $(ls EFI_Backup_$today/CLOVER/drivers64UEFI | grep -v HFSPlus.efi | grep -v VirtualSmc.efi)
  do
    logging "Installing $drivername..."
    driverpath=$(find -f /Volumes/$1/EFI/CLOVER/drivers* -name $drivername)
    cp $driverpath /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
  done

  # Bring HFSPlus.efi over from the backup
  logging "Copying HFSPlus.efi from the EFI backup..."
  cp EFI_Backup_$today/CLOVER/drivers64UEFI/HFSPlus.efi /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
  
  # If there is an ACPI folder, bring it over from the backup
  # This makes sure our DSDTs and SSDTs are there
  if [ -d EFI_Backup_$today/CLOVER/ACPI ]
  then
    logging "Copying DSDTs/SSDTs from the EFI backup..."
    cp -r EFI_Backup_$today/CLOVER/ACPI /Volumes/EFI/EFI/CLOVER/
  fi

  # Get the latest versions of all our kexts
  # SMC sensor kexts are accounted for in the VirtualSMC kext update
  # The extra I2C kexts are accounted for in the VoodooI2C kext update
  for kext in $(ls EFI_Backup_$today/CLOVER/kexts/Other/ | grep -vE "(^SMC)" | grep -vE "VoodooI2C[A-Z]" | grep -vE "FakePCIID_[A-Z]" |  grep -vE "BrcmFirmware[A-Z]")
  do
    install_kext ${kext%*.kext}
  done
}

# Now run it all
today=$(date +%Y_%m_%d)
mkdir EFI_Update_$today
cd EFI_Update_$today
clover_download
efi_mount
efi_prep
clover_configure $clover_source_volume
logging "Unmounting Clover ISO..."
diskutil unmount $clover_source_volume &> /dev/null
logging "Deleting Clover ISO..."
rm $clover_source_volume.iso
logging "Update complete."
mv EFI_Update_$today.log /Volumes/EFI/EFI/