# BadRecovery

BadRecovery (formerly OlyBmmer) is an exploit for ChromeOS devices,
leveraging a vulnerability in recovery images to get arbitrary code execution or to chain to other exploits.

BadRecovery unenrolls ALL devices that are EOL before 2024, and can unenroll current supported devices on kernel version 3 or lower.

The exploit and writeup were released to the public on October 5th, 2024.

You can read the writeup [here](./writeup.md).

## How to use

You will need:
- A USB drive or SD card (8 GB or larger)
- Something to flash the image (dd, rufus, chromebook recovery utility, etc.)
- A ChromeOS device that has not received the patch (see [patch](#patch))

### Preparing an image

First, you must download an official recovery image for your device.
You can download them from [ChromiumDash](https://chromiumdash.appspot.com/serving-builds?deviceCategory=Chrome%20OS) or [Chrome100](https://chrome100.dev/).  
See [modes of operation](#modes-of-operation) for which version you'll need, usually r124 or older.
Be sure you've downloaded the correct image for your device.

Make sure to unzip the recovery image before proceeding to the next step!

Next, you must modify the recovery image using the script included with this repository.
You can use the [web version](https://binbashbanana.github.io/badrecovery/builder.html) of the builder, though it is a fair bit slower.

To get the script, run these commands on a linux machine:
```
git clone https://github.com/BinBashBanana/badrecovery
cd badrecovery
```

To modify a recovery image using the script, run
```
sudo ./build_badrecovery.sh -i <image.bin>
```
(Replace `<image.bin>` with the path to your recovery image bin.)

The script may prompt you to install required dependencies.

You can specify the mode using the `--type` argument (`-t` for short).
If left unspecified, the script will automatically determine the best option based on the version and features of the recovery image.

Example:
```
sudo ./build_badrecovery.sh -i image.bin -t postinst
```
The script would fail if it detected that the supplied recovery image does not meet the requirements for postinst mode (see table below).

The recovery image is now modified, and is ready to be flashed to a USB drive or SD card.

### Running on ChromeOS device

First, enter recovery mode. See [this article](https://support.google.com/chromebook/answer/1080595#enter) for detailed instructions.

> [!IMPORTANT]  
> On the unverified payload, you must also enter developer mode, and then enter recovery mode again for BadRecovery to work.  
> **On Cr50 devices (most devices manufactured in 2018 or later), you must NOT be in developer mode for unenrollment to work. Ensure you are in verified mode recovery.**  
> In any other case, you can use either verified or developer mode recovery.

Plug in the prepared USB drive or SD card. On the unverified payload, BadRecovery will start in only a few seconds if you've done everything correctly.

On any other payload, the system will recover first. This may take a while depending on the speed of your drive.  
On postinst and postinst_sym payloads, BadRecovery will start partway through the recovery process.

> [!NOTE]  
> If using postinst_sym and BadRecovery does not start, the path to the internal drive is incorrect.

On basic or persist payloads, reboot into verified mode after recovery completes.  
Optionally, you can look at VT3 and reboot early to skip postinst and save some time.

On the persist payload, BadRecovery will start within a few seconds of ChromeOS booting.  
On basic, you must proceed through setup and the device will unenroll using [cryptosmite](https://github.com/FWSmasher/CryptoSmite).

When BadRecovery finishes, you will usually be able to skip the 5 minute developer mode delay by immediately switching back into recovery mode to get to developer mode.
(This is not required.)

## Modes of operation

<table>
<tr>
    <th>Mode</th>
    <th>Requirements</th>
    <th>Description</th>
</tr>
<tr>
	<td>postinst</td>
	<td>86 &le; version &le; 124 AND disk layout v1 or v2</td>
	<td>
	ROOT-A (usb) overflows into ROOT-A (internal). Not supported on disk layout v3 (devices with minios).
	Replaces postinst with a custom payload and grants code execution in recovery.
	</td>
</tr>
<tr>
	<td>postinst_sym</td>
	<td>34 &le; version &le; 124 AND (kernel &ge; 4.4 OR year &lt; 2038)</td>
	<td>
	ROOT-A (usb) overflows into STATE (internal).
	Stateful installer copies payload (usb) to a symlink in STATE (internal) which points to ROOT-A (internal).
	Replaces postinst with a custom payload and grants code execution in recovery.
	<br>
	Caveat: internal disk device path must be known.
	</td>
</tr>
<tr>
	<td>persist</td>
	<td>26 &le; version &le; 89 (untested below 68)</td>
	<td>
	ROOT-A (usb) overflows into STATE (internal).
	Encrypted data persisted through cryptosmite, code execution given in ChromeOS through crx-import.
	</td>
</tr>
<tr>
	<td>basic</td>
	<td>26 &le; version &le; 119 (untested below 68)</td>
	<td>
	ROOT-A (usb) overflows into STATE (internal).
	Standard cryptosmite unenrollment payload.
	</td>
</tr>
<tr>
	<td>unverified</td>
	<td>version &le; 41 / version &le; 47 (WP off) / any version (developer mode NOT blocked)</td>
	<td>
	Unverified ROOT-A, developer mode only!
	Use this for very old devices or for testing.
	This is an intended feature, not a bug.
	</td>
</tr>
</table>

All images will be larger than 2 and smaller than 8 GB, except unverified, which is almost always less than 1 GB.

> [!NOTE]  
> Note: for `persist` and `basic`, on version 86 and above (when `postinst` is available), built images are large (8.5 GB)
> for the legacy/v1 disk layout and even larger (17 GB) for disk layout v2. `postinst` should always be preferred anyway.
> If you choose to use either of these modes anyway, some different steps must be taken while installing the recovery image.

## Patch

R125 recovery images and newer are not vulnerable to this (except unverified).
To determine if you can use this, follow these in order:
- Was your device EOL before 2024? → YES
- Are you on ChromeOS version 124 or lower? → YES
- Was your device *released* after mid-2024? → NO
- Does your device show `03` or lower as the last digits of the kernver (kernel version) on the recovery screen (press TAB, look at the line that starts with "TPM")? → YES
- Higher than `03`? → NO

## Known issues

- FWMP doesn't remove on some newer devices (nissa, brya(?), corsola(?))

## Credits

- OlyB/BinBashBanana - most of the work here
- Writable - [cryptosmite](https://github.com/FWSmasher/CryptoSmite) vulnerability
- Rory McNamara - encrypted_import vulnerability
- Bomberfish - the name BadRecovery

### Testers

Big thanks to the testers:

- Juliet (celes)
- M_Wsecond (lars)
- Kelpsea Stem (peppy, nissa)
- Kxtz (relm)
- Desvert (peach-pi)
- WeirdTreeThing (trogdor)
- cmxci (gnawty)

### Dedications

- Percury Mercshop
- Blake Nelsen (kinda)
- Rory McNamara
