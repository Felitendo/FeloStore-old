# Convenience script
$CURR_DIR = Get-Location

try {
    if ($args.Count -eq 0) {
        git fetch
        git merge origin/main
        git push # Typically run after a PR to main, so bring dev up to date
    }

    # Navigate to the .flutter directory
    $flutterDir = "C:\Users\Felix\Documents\GitHub\FeloStore\.flutter"
    if (-Not (Test-Path $flutterDir)) {
        Write-Error "The directory '$flutterDir' does not exist."
        exit 1
    }
    Set-Location $flutterDir

    git fetch
    $flutter_version = flutter --version | Select-String -Pattern "Framework.*v([\d.]+)" | ForEach-Object { $_.Matches.Groups[1].Value }
    git checkout $flutter_version
    Set-Location ..

    # Remove old builds if any
    Remove-Item .\build\app\outputs\flutter-apk\* -ErrorAction SilentlyContinue

    # Build APKs
    flutter build apk --flavor normal
    flutter build apk --split-per-abi --flavor normal

    # Rename files
    Get-ChildItem .\build\app\outputs\flutter-apk\ -Filter "app-*normal*.apk" | ForEach-Object {
        $newName = $_.Name -replace "-normal", ""
        Rename-Item $_.FullName $newName
    }

    # Build F-Droid flavor
    flutter build apk --flavor fdroid -t lib\main_fdroid.dart
    flutter build apk --split-per-abi --flavor fdroid -t lib\main_fdroid.dart

    # Generate PGP signatures
    Get-ChildItem .\build\app\outputs\flutter-apk\ -Filter *.sha1 | ForEach-Object {
        gpg --sign --detach-sig $_.FullName
    }

    # Copy to Downloads folder
    $destination = [System.IO.Path]::Combine($HOME, "Downloads\FeloStore-build")
    if (-Not (Test-Path $destination)) {
        New-Item -Path $destination -ItemType Directory
    }
    Copy-Item .\build\app\outputs\flutter-apk\* $destination -Recurse

    # Create zip files for upload
    Set-Location $destination
    Get-ChildItem -Filter *.apk | ForEach-Object {
        $PREFIX = $_.BaseName.Substring(0, $_.BaseName.Length - 5)
        Compress-Archive -Path "$PREFIX*" -DestinationPath "$PREFIX.zip"
    }

    # Organize zip files
    $zipDir = Join-Path $destination "zips"
    if (-Not (Test-Path $zipDir)) {
        New-Item -Path $zipDir -ItemType Directory
    }
    Move-Item *.zip $zipDir
} finally {
    Set-Location $CURR_DIR
}
