# Builds llama.cpp for Zenzai as CPU-only shared libraries with MSVC and installs
# them (bin\*.dll, lib\*.lib, include\) for build-package.ps1.
#
#   pwsh Windows\scripts\build-llama.ps1 [-WorkDirectory <dir>] [-Parallel <n>]
#
# Run it after enter-dev-shell.ps1. The result is <WorkDirectory>\install.
param(
    [string]$WorkDirectory = (Join-Path $PSScriptRoot '..\..\build\llama-windows'),
    [int]$Parallel = 3
)
$ErrorActionPreference = 'Stop'

# The revision of upstream's macOS llama.xcframework (tag b4846), which the Linux
# packages build too (packaging/docker/Dockerfile.zenzai). The converter's
# systemLibrary target (Sources/llama.cpp) carries its own copy of the headers;
# that copy predates b4846 slightly (an enum renumbering, a few added functions
# and void-to-status returns) but declares every struct and function the
# converter calls identically.
$llamaRepository = 'https://github.com/azooKey/llama.cpp.git'
$llamaRevision = '10131b23ee0dbd9d03dfc618cec9fe3402919277'
# GGML_NATIVE=OFF fixes the instruction set at AVX2 and BMI2 (as on Linux)
# instead of the build machine's, so the package needs an AVX2 CPU. With MSVC,
# ggml derives FMA and F16C from AVX2 (/arch:AVX2) and has no options for them.
$requiredInstructionSets = 'GGML_AVX', 'GGML_AVX2', 'GGML_BMI2'
# The package ships only the Visual C++ runtime that comes with Swift's runtime
# (msvcp140*, vcruntime140*); anything else would be missing on a clean machine.
$allowedRuntimeImports = '^(msvcp140.*|vcruntime140.*|api-ms-win-.*|kernel32|advapi32|ggml.*|llama)\.dll$'

function Invoke-Checked {
    param([string]$Description, [scriptblock]$Command)
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed ($LASTEXITCODE)" }
}

New-Item -ItemType Directory -Force -Path $WorkDirectory | Out-Null
$WorkDirectory = (Resolve-Path $WorkDirectory).Path
$source = Join-Path $WorkDirectory 'source'
$build = Join-Path $WorkDirectory 'build'
$install = Join-Path $WorkDirectory 'install'
foreach ($directory in $source, $build, $install) {
    if (Test-Path $directory) { Remove-Item -Recurse -Force $directory }
}

Invoke-Checked 'git init' { git init --quiet $source }
Invoke-Checked 'git fetch' { git -C $source fetch --quiet --depth=1 $llamaRepository $llamaRevision }
Invoke-Checked 'git checkout' { git -C $source checkout --quiet --detach FETCH_HEAD }
# The commit id is the hash of the whole tree, so matching it verifies the source.
$fetchedRevision = (git -C $source rev-parse 'HEAD^{commit}').Trim()
if ($fetchedRevision -ne $llamaRevision) {
    throw "llama.cpp revision mismatch: expected $llamaRevision, got $fetchedRevision"
}

# Swift's toolchain puts clang on PATH ahead of MSVC; ggml is C and llama is C++.
# Without OpenMP ggml uses its own thread pool, so nothing needs MSVC's OpenMP
# runtime (vcomp140.dll), which the package does not ship.
Invoke-Checked 'cmake configure' {
    cmake -S $source -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release `
        -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl -DCMAKE_INSTALL_PREFIX="$install" `
        -DBUILD_SHARED_LIBS=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF `
        -DLLAMA_CURL=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF `
        -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF
}
# GGML_NATIVE_DEFAULT turns OFF when SOURCE_DATE_EPOCH is set, and with it every
# instruction set, which would silently produce a scalar build.
$cache = Get-Content (Join-Path $build 'CMakeCache.txt')
foreach ($name in $requiredInstructionSets) {
    if (-not ($cache -match "^${name}:BOOL=ON$")) { throw "$name is not enabled in the llama.cpp build" }
}
Invoke-Checked 'cmake build' { cmake --build $build --parallel $Parallel }
Invoke-Checked 'cmake install' { cmake --install $build }

foreach ($library in Get-ChildItem (Join-Path $install 'bin') -Filter '*.dll') {
    # dumpbin lists each imported DLL by bare name on its own line.
    $imports = dumpbin /nologo /dependents $library.FullName | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[\w.-]+\.dll$' }
    $unexpected = $imports | Where-Object { $_ -notmatch $allowedRuntimeImports }
    if ($unexpected) { throw "$($library.Name) imports DLLs the package does not ship: $($unexpected -join ', ')" }
}
Write-Output "llama.cpp $llamaRevision installed: $install"
