# Declare our functions

# Returns a link to download a given kext
install_kext () {
  # This function takes a kext name, and installs it to the EFI
  # Pretty much only works for acidanthera's kexts right now, but let's be honest, that's pretty much all the important ones

  # If there are some options
  case "${1}" in
    AppleALC|Lilu|WhateverGreen)
      $reponame=$1
      # Get the latest GitHub releast
      url=https://api.github.com/repos/acidanthera/$1/releases/latest
      # Use the GitHub API (plus a little parameter expansion magic) to get the URL of the latest release
      url=$(curl $url | grep browser_download_url | grep RELEASE | awk '{print $2}')
      url=${url%','} # remove trailing comma from the result
      url=${url%'"'} # remove trailing " from the result
      url=${url#'"'} # remove leading " from the result
      # Download the kext
      get_kext $url $reponame
      # Get the path to the kext
      kext_path=$(find $reponame -name $reponame.kext)
      # Put the kext in the EFI partition
      cp -r $kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/
      # Cleanup
      rm -rf $reponame
      ;;
    VirtualSMC)
      $reponame=$1
      # Get the latest GitHub releast
      url=https://api.github.com/repos/acidanthera/$1/releases/latest
      # Use the GitHub API (plus a little parameter expansion magic) to get the URL of the latest release
      url=$(curl $url | grep browser_download_url | grep RELEASE | awk '{print $2}')
      url=${url%','} # remove trailing comma from the result
      url=${url%'"'} # remove trailing " from the result
      url=${url#'"'} # remove leading " from the result
      
      # Download the kext
      get_kext $url $reponame

      # Get the path to the kext
      kext_path=$(find $reponame -name $reponame.kext)
      # Put the kext in the EFI partition
      cp -r $kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other/

      # Update the EFI driver
      driver_path=$(find $reponame -name $reponame.efi)
      cp $driver_path /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
      
      # Update our SMC sensor kexts
      for smc_kext in $(ls EFI_Backup_$today/kexts/Other/SMC*)
      do
        smc_kext_path=$(find $reponame -name $smc_kext.kext)
        cp -r $smc_kext_path /Volumes/EFI/EFI/CLOVER/kexts/Other
      done
      ;;
    *)
      usage
      ;;
    esac
}


clover_download() {
  ###
  # CODE TO DOWNLOAD THE ISO
  ###

  # Get the name of the latest Clover ISO
  cloverfile=$(curl https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/ 2> /dev/null |  grep -Eo -m 1 "(CloverISO-.....tar.lzma)")
  
  # Download the latest Clover ISO
  wget https://sourceforge.net/projects/cloverefiboot/files/Bootable_ISO/$cloverfile/download -O $cloverfile
  
  # Get the release number from the tarball's name
  cloverrelease=${cloverfile#CloverISO-*}
  cloverrelease=${cloverrelease%*.tar.lzma}

  # Extract the tarball
  tar --lzma -xf $cloverfile 2>&1 /dev/null

  # Delete the tarball
  rm $cloverfile

  # Set the ISO name, based on the release name
  iso=Clover-v2.4k-$cloverrelease-X64.iso

  # Mount the ISO
  hdiutil mount $iso 2>&1 /dev/null
  
  # Return the volume name
  export clover_source_volume=${iso%*.iso}

  ###
  # CODE TO DOWNLOAD THE ZIP
  # UNUSED
  ###
  # Get latest Clover zip
  #wgetoutput=$(wget https://sourceforge.net/projects/cloverefiboot/files/latest/download -O latest_clover.zip 2>&1)

  # Match regex for Clover zip file name
  #$clovername=$(echo $wgetoutput | grep -Eo -m 1 "(Clover_v2.4k_r.....zip)")
  # Rename the downloaded file
  #mv latest_clover.zip $clovername
  # Unzip the file
  #unzip $clovername
}

get_kext() {
  # This function downloads a zip file, and extracts it
  url=$1
  reponame=$2
  # Download it
  wget $url

  # Get the name of the file we downloaded
  zip_name=${url##*'/'}

  # Extract the archive
  unzip $zip_name -d $reponame

  # Post-extraction cleanup
  rm $zip_name
}

efi_mount() {
  # Get the EFI partition on the primary disk
  $efi=$(diskutil list | grep disk0 | grep EFI | awk '{print $6}')

  # Mount it
  diskutil mount $efi
}

efi_prep() {
  # Backup the current EFI, we need it for reference anyway
  set -e
  cp -r /Volumes/EFI/EFI EFI_Backup_$today
  set +e

  # Clean out the EFI partition for a fresh installation of Clover
  rm -rf /Volumes/EFI/EFI
}

clover_prep() {
  # Build out a Clover skeleton
  mkdir -p /Volumes/EFI/EFI/BOOT /Volumes/EFI/EFI/CLOVER/kexts /Volumes/EFI/EFI/CLOVER/drivers64UEFI
  cp -r /Volumes/$1/EFI/BOOT/* /Volumes/EFI/EFI/BOOT
  cp -r /Volumes/$1/EFI/CLOVER/themes /Volumes/EFI/EFI/CLOVER/
  cp -r /Volumes/$1/EFI/CLOVER/tools /Volumes/EFI/EFI/CLOVER/
  cp /Volumes/$1/EFI/CLOVER/CLOVERX64.efi /Volumes/EFI/EFI/CLOVER/
}

clover_configure(){
  clover_prep $1
  # Copy over our config.plist
  cp EFI_Backup_$today/CLOVER/config.plist /Volumes/EFI/EFI/CLOVER/

  # Get the latest drivers
  # HFSPlus.efi is skipped because it doesn't change, though we could sum the one on GitHub against the current one
  # VirtualSMC.efi is in the VirtualSMC release package, so it is updated when VirtualSMC.kext is updated
  for drivername in $(ls EFI_Backup_$today/CLOVER/drivers64UEFI | grep -v HFSPlus.efi | grep -v VirtualSMC.efi)
  do
    $driverpath=$(find -f /Volumes/$1/EFI/CLOVER/drivers* -name $drivername)
    cp $driverpath /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
  done

  # Bring HFSPlus.efi over from the backup
  cp EFI_Backup_$today/drivers64UEFI/HFSPlus.efi /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
  
  # If there is an ACPI folder, bring it over from the backup
  # This makes sure our DSDTs and SSDTs are there
  if [ -d EFI_Backup_$today/ACPI ]
  then
    cp -r EFI_Backup_$today/ACPI /Volumes/EFI/EFI/CLOVER/
  fi

  # Get the latest versions of all our kexts
  # SMC sensor kexts are accounted for in the VirtualSMC kext update
  for kext in $(ls EFI_Backup_$today/kexts/Other/ | grep -v SMC*.kext)
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


#install clover with correct drivers
#delete 
#    clover install log
#    if all acpi folders in the backup are empty, delete acpi
#    doc
#    misc
#    oem
#    rom
#    kexts/10.*
#check virtualsmc version between backup and downloaded release
