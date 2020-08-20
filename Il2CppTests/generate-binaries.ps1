﻿# Copyright 2019-2020 Katy Coe - http://www.djkaty.com - https://github.com/djkaty
# All rights reserved.

# Compile all of the test items in TestSources via IL2CPP to produce the binaries necessary to run the tests
# Requires Unity 2019.2.8f1 or later and Visual Studio 2017 (or MSBuild with C# 7+ support) or later to be installed
# Requires Android NDK r13b or newer for Android test builds (https://developer.android.com/ndk/downloads)

param (
	# Which assemblies in the TestAssemblies folder to generate binaries for with il2cpp
	[string]$assemblies = "*",

	# Which Unity version to use; uses the latest installed if not specified
	[string]$unityVersion = "*"
)

$ErrorActionPreference = "SilentlyContinue"

# Path to C¤ compiler (14.0 = Visual Studio 2017, 15.0 = Visual Studio 2019 etc.)
# These are ordered from least to most preferred. If no files exist at the specified path,
# a silent exception will be thrown and the variable will not be re-assigned.

# Look for Unity Roslyn installs
$CSC = (gci "$env:ProgramFiles\Unity\Hub\Editor\$unityVersion\Editor\Data\Tools\Roslyn\csc.exe" | sort FullName)[-1].FullName
# Look for .NET Framework installs
$CSC = (gci "${env:ProgramFiles(x86)}\MSBuild\*\Bin\csc.exe" | sort FullName)[-1].FullName
# Look for Visual Studio Roslyn installs
$CSC = (gci "${env:ProgramFiles(x86)}\Microsoft Visual Studio\*\*\MSBuild\*\Bin\Roslyn\csc.exe" | sort FullName)[-1].FullName

# Path to latest installed version of Unity
# The introduction of Unity Hub changed the base path of the Unity editor
$UnityPath = (gci "$env:ProgramFiles\Unity\Hub\Editor\$unityVersion\Editor\Data" | sort FullName)[-1].FullName

# Path to il2cpp.exe
# Up to Unity 2019.2, il2cpp\build\il2cpp.exe
# From Unity 2019.3, il2cpp\build\deploy\net471\il2cpp.exe
$il2cpp = (gci "$UnityPath\il2cpp\build" -Recurse -Filter il2cpp.exe)[0].FullName

# Path to mscorlib.dll
# Up to Unity 2019.2, Mono\lib\mono\unity\...
# From Unity 2019.3, MonoBleedingEdge\lib\mono\unityaot\...
$mscorlib = (gci "$UnityPath\Mono*\lib\mono\unityaot\mscorlib.dll")[0].FullName

# Path to the Android NDK
# Different Unity versions require specific NDKs, see the section Change the NDK at:
# The NDK can also be installed standalone without AndroidPlayer
# https://docs.unity3d.com/2019.1/Documentation/Manual/android-sdksetup.html
$AndroidPlayer = $UnityPath + '\PlaybackEngines\AndroidPlayer'
$AndroidNDK = $AndroidPlayer + '\NDK'

$ErrorActionPreference = "Continue"

# Check that everything is installed
if (!$CSC) {
	Write-Error "Could not find C¤ compiler csc.exe - aborting"
	Exit
}

if (!$UnityPath) {
	Write-Error "Could not find Unity editor - aborting"
	Exit
}

if (!(Test-Path -Path $AndroidNDK -PathType container)) {
	Write-Error "Could not find Android NDK at '$AndroidNDK' - aborting"
	Exit
}

if (!$il2cpp) {
	Write-Error "Could not find Unity IL2CPP build support - aborting"
	Exit
}

if (!$mscorlib) {
	Write-Error "Could not find Unity mscorlib assembly - aborting"
	Exit
}

if (!(Test-Path -Path $AndroidPlayer -PathType container)) {
	Write-Error "Could not find Unity Android build support - aborting"
	Exit
}

echo "Using C# compiler at '$CSC'"
echo "Using Unity installation at '$UnityPath'"
echo "Using IL2CPP toolchain at '$il2cpp'"
echo "Using Unity mscorlib assembly at '$mscorlib'"
echo "Using Android player at '$AndroidPlayer'"
echo "Using Android NDK at '$AndroidNDK'"

# Workspace paths
$src = "$PSScriptRoot/TestSources"
$asm = "$PSScriptRoot/TestAssemblies"
$cpp = "$PSScriptRoot/TestCpp"
$bin = "$PSScriptRoot/TestBinaries"

# We try to make the arguments as close as possible to a real Unity build
# "--lump-runtime-library" was added to reduce the number of C++ files generated by UnityEngine (Unity 2019)
# "--disable-runtime-lumping" replaced the above (Unity 2019.3)
$arg =	'--convert-to-cpp', '--compile-cpp', '--libil2cpp-static', '--configuration=Release', `
		'--emit-null-checks', '--enable-array-bounds-check', '--forcerebuild', `
		'--map-file-parser=$UnityPath\il2cpp\MapFileParser\MapFileParser.exe', '--dotnetprofile="unityaot"'

# Prepare output folders
md $asm, $bin 2>&1 >$null

# Compile all .cs files in TestSources
echo "Compiling source code..."
gci $src | % {
	echo $_.BaseName

	& $csc "/t:library" "/nologo" "/unsafe" "/out:$asm/$($_.BaseName).dll" "$src/$_"
	
	if ($LastExitCode -ne 0) {
		Write-Error "Compilation error - aborting"
		Exit
	}
}

# Run IL2CPP on all generated assemblies for both x86 and ARM
# Earlier builds of Unity included mscorlib.dll automatically; in current versions we must specify its location
gci $asm -filter $assemblies | % {
	# x86
	$name = "GameAssembly-$($_.BaseName)-x86"
	echo "Running il2cpp for test assembly $name (Windows/x86)..."
	md $bin/$name 2>&1 >$null
	rm -Force -Recurse $cpp/$name
	& $il2cpp $arg '--platform=WindowsDesktop', '--architecture=x86', `
				"--assembly=$asm/$_,$mscorlib", `
				"--outputpath=$bin/$name/$name.dll", `
				"--generatedcppdir=$cpp/$name"
	if ($LastExitCode -ne 0) {
		Write-Error "IL2CPP error - aborting"
		Exit
	}

	mv -Force $bin/$name/Data/metadata/global-metadata.dat $bin/$name
	rm -Force -Recurse $bin/$name/Data

	# x64
	$name = "GameAssembly-$($_.BaseName)-x64"
	echo "Running il2cpp for test assembly $name (Windows/x64)..."
	md $bin/$name 2>&1 >$null
	rm -Force -Recurse $cpp/$name
	& $il2cpp $arg '--platform=WindowsDesktop', '--architecture=x64', `
				"--assembly=$asm/$_,$mscorlib", `
				"--outputpath=$bin/$name/$name.dll", `
				"--generatedcppdir=$cpp/$name"
	if ($LastExitCode -ne 0) {
		Write-Error "IL2CPP error - aborting"
		Exit
	}
	mv -Force $bin/$name/Data/metadata/global-metadata.dat $bin/$name
	rm -Force -Recurse $bin/$name/Data

	# ARMv7
	$name = "$($_.BaseName)-ARMv7"
	echo "Running il2cpp for test assembly $name (Android/ARMv7)..."
	md $bin/$name 2>&1 >$null
	rm -Force -Recurse $cpp/$name
	& $il2cpp $arg '--platform=Android', '--architecture=ARMv7', `
				"--assembly=$asm/$_,$mscorlib", `
				"--outputpath=$bin/$name/$name.so", `
				"--generatedcppdir=$cpp/$name", `
				"--additional-include-directories=$AndroidPlayer/Tools/bdwgc/include" `
				"--additional-include-directories=$AndroidPlayer/Tools/libil2cpp/include" `
				"--tool-chain-path=$AndroidNDK"
	if ($LastExitCode -ne 0) {
		Write-Error "IL2CPP error - aborting"
		Exit
	}
	mv -Force $bin/$name/Data/metadata/global-metadata.dat $bin/$name
	rm -Force -Recurse $bin/$name/Data

	# ARMv8 / A64
	$name = "$($_.BaseName)-ARM64"
	echo "Running il2cpp for test assembly $name (Android/ARM64)..."
	md $bin/$name 2>&1 >$null
	rm -Force -Recurse $cpp/$name
	& $il2cpp $arg '--platform=Android', '--architecture=ARM64', `
				"--assembly=$asm/$_,$mscorlib", `
				"--outputpath=$bin/$name/$name.so", `
				"--generatedcppdir=$cpp/$name", `
				"--additional-include-directories=$AndroidPlayer/Tools/bdwgc/include" `
				"--additional-include-directories=$AndroidPlayer/Tools/libil2cpp/include" `
				"--tool-chain-path=$AndroidNDK"
	if ($LastExitCode -ne 0) {
		Write-Error "IL2CPP error - aborting"
		Exit
	}
	mv -Force $bin/$name/Data/metadata/global-metadata.dat $bin/$name
	rm -Force -Recurse $bin/$name/Data
}

# Generate test stubs
& "$PSScriptRoot/generate-tests.ps1"
