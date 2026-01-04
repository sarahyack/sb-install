# sb-install (Secure Boot Installation Script)

## Purpose

The general intention of this script is to provide an ease-of-use script to accomplish key generation, signing, shim-lock, and shim-lock support for GRUB on Arch-based distros, specifically EndeavourOS, although other distributions should also technically work.

> [!warning]
> This script has not been tested extensively, so unexpected outcomes could theoretically occur.

## Usage

Ensure Secure Boot is disabled on your machine before you begin.

1. Clone this repository

    ```shell
    git clone https://github.com/sarahyack/sb-install
    ```

2. Enter the Cloned repository

    ```shell
    cd sb-install
    ```

3. Make the install script executable from the directory you cloned the repo into **(See Note)**:

    ```shell
    chmod +x install.sh
    ```

4. Run the Installation Script

    ```shell
    ./install.sh
    ```


> [!note] 
> It's generally recommended when making an external script executable to look it over first and ensure you understand what it's changing in your machine.

### After Installation

The Final Steps to take after running the installation script are:

1) Reboot and enable Secure Boot in firmware if needed. 
2) If shim does not find the certificate that grubx64.efi is signed with in MokList, it will launch MokManager (mmx64.efi). 
    - In MokManager: 
        - Enroll key from disk
            1. find MOK.cer on the ESP (often at \MOK.cer or \EFI\BOOT\MOK.cer) 
            2. enroll it to MokList 
            3. Continue boot 
3) Reboot again; Secure Boot should be working.

## What it Does

The general breakdown is that it installs `sbctl` to handle the grunt work of getting the Machine Owner Keys (MOK) installed and enrolled on your machine, and then proceeds to enable and set up shim-lock for your machine and then enable GRUB shim-lock support.




