const minDiskSize = (6 * 1024 * 1024 * 1024); // 6 GiB
const maxSingleAlloc = 1024 * 1024 * 1024; // 1 GiB
let builderOptions = document.getElementById("builderOptions");
let startButton = document.getElementById("startButton");
let downloadButton = document.getElementById("downloadButton");
let displayContainer = document.getElementById("displayContainer");
let linuxOutput = document.getElementById("linuxOutput");
let builderOutput;
let building = false;
let builderTextOut = "";
let builderOutputIO;
let curLoadingFile = "";
let uploadedName = "image.bin";

function uploadFile(accept, callback) {
	var input = document.createElement("input");
	input.type = "file";
	input.accept = accept;
	input.onchange = async function() {
		callback(this.files[0]);
	}
	input.click();
}

function unzipFile(data) {
	return new Promise(async function(resolve, error) {
		let entries = await new zip.ZipReader(new zip.Uint8ArrayReader(new Uint8Array(data))).getEntries();
		if (entries.length) {
			for (var i = 0; i < entries.length; i++) {
				if (!entries[i].directory) {
					resolve(await entries[i].getData(new zip.Uint8ArrayWriter()));
					break;
				}
				if (i == entries.length - 1) error();
			}
		}
		error();
	});
}

function getTime() {
	var dateTime = new Date();
	return dateTime.getFullYear().toString()+"-"+(dateTime.getMonth()+1).toString()+"-"+dateTime.getDate().toString()+"-"+dateTime.getHours().toString()+"-"+dateTime.getMinutes().toString();
}

function progressFetch(url) {
	return new Promise(function(success, fail) {
		var req = new XMLHttpRequest();
		req.open("GET", url, true);
		req.responseType = "arraybuffer";
		req.onload = function() {
			if (req.status >= 400) {
				if (fail) fail(req.status);
			} else {
				if (success) success(this.response);
			}
		}
		req.onprogress = function(e) {
			if (e.lengthComputable) updateLoadProgress(url, e.loaded / e.total);
		}
		req.onerror = function() {
			if (fail) fail("unknown");
		}
		req.send();
	});
}

async function fetchWebBuilderTar() {
	console.log("fetching webbuilder.tar.zip");
	var webBuilderTarZip = await progressFetch("assets/webbuilder.tar.zip");
	var webBuilderTar = await unzipFile(webBuilderTarZip);
	return webBuilderTar;
}

function sleep(ms) {
	return new Promise(function(resolve) {
		setTimeout(resolve, ms);
	});
}

async function growBlob(blob, size) {
	var totalAddedSize = size - blob.size;
	var totalSizeToAdd = totalAddedSize;
	var err = false;
	while (totalSizeToAdd > 0) {
		var addedSize = Math.min(totalAddedSize, maxSingleAlloc);
		try {
			blob = new Blob([blob, new ArrayBuffer(addedSize)]);
		} catch (e) {
			console.error(e);
			err = true;
			break;
		}
		totalSizeToAdd -= addedSize;
		updateLoadProgress("(growing blob)", Math.min(1, 1 - (totalSizeToAdd / totalAddedSize)));
		await sleep(0);
	}
	if (err) builderOutputIO.print("\r\nWarning: failed to grow blob...\r\n");
	return blob;
}

async function doneBuilding() {
	console.log("done building");
	var finalSizeFile = await emulator.read_file("/finalsize");
	var finalBytes = parseInt(new TextDecoder().decode(finalSizeFile));
	console.log("final bytes: " + finalBytes);
	var blob = emulator.disk_images.hda.get_as_file().slice(0, finalBytes, "application/octet-stream");
	downloadButton.download = "badrecovery_" + getTime() + "_" + uploadedName;
	downloadButton.href = URL.createObjectURL(blob);
	downloadButton.style.display = "block";
	downloadButton.click();
}

function updateLoadProgress(name, percent) {
	if (name != curLoadingFile) {
		if (curLoadingFile.length) builderOutputIO.print("\n");
		curLoadingFile = name;
	}
	builderOutputIO.print("\rLoading " + name + " " + Math.round(percent * 100) + "%  ");
}

async function initFromFile(file) {
	uploadedName = file.name;
	if (file.size < minDiskSize) file = new File([await growBlob(file, minDiskSize)], file.name);
	builderOptions.querySelectorAll("input, select").forEach(e => e.setAttribute("disabled", ""));
	startButton.style.display = "none";
	linuxOutput.textContent = "Loading...";
	displayContainer.style.display = "block";
	console.log("creating emulator...");
	window.emulator = new V86Starter({
		wasm_path: "assets/v86.wasm",
		memory_size: 512 * 1024 * 1024,
		vga_memory_size: 2 * 1024 * 1024,
		screen_container: document.getElementById("screen_container"),
		bios: {
			url: "assets/seabios.bin"
		},
		vga_bios: {
			url: "assets/vgabios.bin"
		},
		bzimage: {
			url: "assets/bzImage"
		},
		initrd: {
			url: "assets/rootfs.cpio.gz"
		},
		hda: {
			buffer: file
		},
		filesystem: {},
		autostart: false
	});
	emulator.add_listener("download-progress", function(p) {
		if (p.lengthComputable) updateLoadProgress(p.file_name, p.loaded / p.total);
	});
	emulator.add_listener("emulator-ready", async function() {
		var optsBool = Array.from(builderOptions.querySelectorAll("input[type=checkbox]"));
		for (var i = 0; i < optsBool.length; i++) {
			if (optsBool[i].checked) await emulator.create_file("/opt." + optsBool[i].name, new Uint8Array());
		}
		var optsText = Array.from(builderOptions.querySelectorAll("select"));
		for (var i = 0; i < optsText.length; i++) {
			if (optsText[i].value) await emulator.create_file("/opt." + optsText[i].name, new TextEncoder().encode(optsText[i].value));
		}
		await emulator.create_file("/web.tar", await fetchWebBuilderTar());
		console.log("running...");
		emulator.run();
	});
	emulator.add_listener("serial0-output-byte", async function(byte) {
		builderOutputIO.writeUTF8(new Uint8Array([byte]));
		builderTextOut += String.fromCharCode(byte);
		if (builderTextOut.endsWith("Done building!")) {
			building = false;
			doneBuilding();
		}
	});
	function writeData(str) {
		emulator.serial0_send(str);
	}
	builderOutputIO.onVTKeystroke = writeData;
	builderOutputIO.sendString = writeData;
	building = true;
}

function loadWebBuilder() {
	builderOutput = new hterm.Terminal({storage: new lib.Storage.Memory()});
	builderOutput.decorate(document.getElementById("builderOutput"));
	builderOutput.installKeyboard();
	builderOutput.onTerminalReady = function() {
		builderOutput.setFontSize(13);
		builderOutputIO = builderOutput.io.push();
		builderOutputIO.print("\x1b[?25l");
		startButton.addEventListener("click", function() {
			uploadFile(".bin, .img", initFromFile);
		}, false);
		startButton.classList.remove("disabled");
	}
}

window.addEventListener("load", loadWebBuilder, false);
window.onbeforeunload = function() {
	if (building) return true;
}
