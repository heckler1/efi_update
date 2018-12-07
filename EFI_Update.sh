today=$(date +%Y_%m_%d)
mkdir EFI_Update_$today
cd EFI_Update_$today

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
  tar --lzma -xf $cloverfile

  # Delete the tarball
  rm $cloverfile

  # Set the ISO name, based on the release name
  iso=Clover-v2.4k-$cloverrelease-X64.iso

  # Mount the ISO
  hdiutil mount $iso

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
  # This function takes a GitHub username and repo name as arguments, and downloads the latest release of the given repo
  # Pretty much only works for acidanthera's kexts right now, but let's be honest, that's pretty much all the important ones

  # Set friendly variable names
  username=$1
  reponame=$2

  # Use the GitHub API (plus a little parameter expansion magic) to get the URL of the latest release
  url=$(curl https://api.github.com/repos/$username/$reponame/releases/latest | grep browser_download_url | grep RELEASE | awk '{print $2}')
  url=${url%','} # remove trailing comma from the result
  url=${url%'"'} # remove trailing " from the result
  url=${url#'"'} # remove leading " from the result

  # Download it
  wget $url

  # Get the name of the file we downloaded
  zip_name=${url##*'/'}

  # Extract the archive
  unzip $zip_name

  # Post-extraction cleanup
  rm $zip_name

  # Put the kext in the EFI partition
  cp -r $reponame.kext /Volumes/EFI/EFI/CLOVER/kexts/Other/

  # More cleanup
  rm -rf $reponame.*
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
  cp -r /Volumes/${iso%*.iso}/EFI/BOOT/* /Volumes/EFI/EFI/BOOT
  cp -r /Volumes/${iso%*.iso}/EFI/CLOVER/themes /Volumes/EFI/EFI/CLOVER/
  cp -r /Volumes/${iso%*.iso}/EFI/CLOVER/tools /Volumes/EFI/EFI/CLOVER/
  cp /Volumes/${iso%*.iso}/EFI/CLOVER/CLOVERX64.efi /Volumes/EFI/EFI/CLOVER/
}

clover_configure(){
  # Copy over our config.plist
  cp EFI_Backup_$today/CLOVER/config.plist /Volumes/EFI/EFI/CLOVER/

  # Get the latest drivers
  for drivername in $(ls EFI_Backup_$today/CLOVER/drivers64UEFI)
  do
    $driverpath=$(find -f /Volumes/${iso%*.iso}/EFI/CLOVER/drivers* -name $drivername)
    cp $driverpath /Volumes/EFI/EFI/CLOVER/drivers64UEFI/
  done

  # Get the latest versions of all our kexts
  ### TODO Map users to kexts
  ### FOR LOOP FOR THIS
  get_kext 
}

clover_download
efi_mount
efi_prep
clover_prep
clover_configure


#install clover with correct drivers
#delete 
#    clover install log
#    if all acpi folders in the backup are empty, delete acpi
#    doc
#    misc
#    oem
#    rom
#    kexts/10.*
#copy hfsplus from the backup to the new install in efi partition
#check virtualsmc version between backup and downloaded release
#install config.plist from backup