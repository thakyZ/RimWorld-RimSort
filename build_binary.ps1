using namespace System;
using namespace System.Collections;
using namespace System.Collections.Generic;
using namespace System.Collections.ObjectModel;
using namespace System.Diagnostics;
using namespace System.Diagnostics.CodeAnalysis;
using namespace System.IO;
using namespace System.Linq;
using namespace System.Management;
using namespace System.Management.Automation;
using namespace System.Net;
using namespace System.Security.Cryptography;
using namespace System.Security.Principal;
using namespace System.ServiceProcess;
using namespace System.Text;
using namespace System.Text.Json;
using namespace System.Text.RegularExpressions;
using namespace Microsoft.Automation;
using namespace Microsoft.PowerShell.Commands;

# cSpell:ignore uiaccess, idgs

[CmdletBinding()]
Param (
  [Parameter(Mandatory = $False,
    HelpMessage = 'Versioning format')]
  [ValidateNotNullOrWhiteSpace()]
  [string]
  $VersionFormat = 'v${major}.${minor}.${patch}',
  [Parameter(Mandatory = $False,
    HelpMessage = 'Generate attestations')]
  [ValidateNotNull()]
  [bool]
  $AtTest = $True,
  [Parameter(Mandatory = $False,
    HelpMessage = 'Github Secret')]
  [AllowNull()]
  [SecureString]
  $GitHubToken
)

Begin {
  [string] $OS = 'windows-latest';
  [string] $Platform = 'Windows';
  [string] $Arch = 'x86_64';
  [string] $env:BUILD_OUTPUT = '__main__.dist';
  [string] $env:Executable = 'RimSort.exe';

  If ($PSBoundParameters.ContainsKey('GitHubToken') -and $Null -ne $GitHubToken) {
    $env:GitHubToken = (ConvertFrom-SecureString -SecureString $GitHubToken -AsPlainText);
  } ElseIf ($PSBoundParameters.ContainsKey('GitHubToken') -and $Null -eq $GitHubToken) {
    $env:GitHubToken = (Read-Host -Prompt 'GitHub Token:' -MaskInput);
  } ElseIf (-not $PSBoundParameters.ContainsKey('GitHubToken') -and $Null -eq $GitHubToken -and $Null -ne $env:GitHubToken) {
    $env:GitHubToken = $env:GitHubToken;
  }

  [FileInfo[]] $PythonEnvActivatePath = @(Get-ChildItem -Path "$($PWD.Path)\*\Scripts\activate.ps1");
  & ($PythonEnvActivatePath | Select-Object -First 1).FullName;
} Process {
  Try {
    # Add submodules to pythonpath

    If ($IsWindows) {
      $env:PYTHONPATH = "$env:PYTHONPATH;$($PWD.Path)\submodules\SteamworksPy"
    } Else {
      $env:PYTHONPATH = "$env:PYTHONPATH;$($PWD.Path)/submodules/SteamworksPy"
    }

    # Remove problematic brew libs

    If ($IsMacOS) {
      & brew remove --force --ignore-dependencies 'openssl@3' 2>&1 | Out-Host;
      & brew cleanup 'openssl@3' 2>&1 | Out-Host;
    }

    # Get semantic version
    # TODO: https://github.com/PaulHatch/semantic-version
    Function Get-SemanticVersion {
      [CmdletBinding()]
      [OutputType([PSCustomObject])]
      Param(
        [Parameter(Mandatory = $False,
          HelpMessage = 'The prefix to use to identify tags')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $TagPrefix = 'v',
        [Parameter(Mandatory = $False,
          HelpMessage = "A string which, if present in a git commit, indicates that a change represents a major (breaking) change, supports regular expressions wrapped with '/'")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MajorPattern = '(MAJOR)',
        [Parameter(Mandatory = $False,
          HelpMessage = "A string which indicates the flags used by the `MajorPattern` regular expression. Supported flags: idgs")]
        [ValidatePattern('[idgs]{1,4}')]
        [string]
        $MajorRegExpFlags = '',
        [Parameter(Mandatory = $False,
          HelpMessage = "Same as above except indicating a minor change, supports regular expressions wrapped with '/'")]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $MinorPattern = '(MINOR)',
        [Parameter(Mandatory = $False,
          HelpMessage = "A string which indicates the flags used by the `MinorPattern` regular expression. Supported flags: idgs")]
        [ValidatePattern('[idgs]{1,4}')]
        [string]
        $MinorRegExpFlags = '',
        [Parameter(Mandatory = $False,
          HelpMessage = 'A string to determine the format of the version output')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $VersionFormat = '${major}.${minor}.${patch}-prerelease${increment}',
        [Parameter(Mandatory = $False,
          HelpMessage = "Optional path to check for changes. If any changes are detected in the path the 'changed' output will true. Enter multiple paths separated by spaces.")]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $ChangePath = @('src/my-service'),
        [Parameter(Mandatory = $False,
          HelpMessage = 'Named version, will be used as suffix for name version tag')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Namespace = 'my-service',
        [Parameter(Mandatory = $False,
          HelpMessage = 'If this is set to true, *every* commit will be treated as a new version.')]
        [bool]
        $BumpEachCommit = $False,
        [Parameter(Mandatory = $False,
          HelpMessage = 'If BumpEachCommit is also set to true, setting this value will cause the version to increment only if the pattern specified is matched.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $BumpEachCommitPatchPattern = '',
        [Parameter(Mandatory = $False,
          HelpMessage = "The output method used to generate list of users, 'csv' or 'json'.")]
        [ValidateSet('csv', 'json')]
        [string]
        $UserFormatType = 'csv',
        [Parameter(Mandatory = $False,
          HelpMessage = 'Prevents pre-v1.0.0 version from automatically incrementing the major version. If enabled, when the major version is 0, major releases will be treated as minor and minor as patch. Note that the version_type output is unchanged.')]
        [bool]
        $EnablePrereleaseMode = $True,
        [Parameter(Mandatory = $False,
          HelpMessage = 'If true, the branch will be used to select the maximum version.')]
        [bool]
        $VersionFromBranch = $False
      )

      Begin {
        [PSCustomObject] $Output = [PSCustomObject]::new();
        [int]      $Major = 0;
        [int]      $Minor = 0;
        [int]      $Patch = 0;
        [int]      $Increment = 0;
        [string]   $VersionType = [string]::Empty;
        [string]   $FormattedVersion = [string]::Empty;
        [string]   $VersionTag = [string]::Empty;
        [string[]] $Authors = @();
        [bool]     $Changed = $False;
        [bool]     $IsTagged = $False;
        [string]   $PreviousCommit = [string]::Empty;
        [string]   $PreviousVersion = [string]::Empty;
        [string]   $CurrentCommit = [string]::Empty;
        [string[]] $DebugOutput = @();
        [string]   $Repository = [string]::Empty;

        If ($PSVersionTable.PSVersion.Major -ge 7) {
          $Repository = ($env:GITHUB_REPOSITORY ?? $PSScriptRoot);
        } Else {
          If (-not ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY))) {
            $Repository = $env:GITHUB_REPOSITORY;
          } Else {
            $Repository = $PSScriptRoot;
          }
        }

        if (-not $Changed) {
          Write-Host -Object 'No changes detected for this commit';
        }

        Write-Host -Object "Version is $($FormattedVersion)";

        if (-not [string]::IsNullOrWhiteSpace($Repository)) {
          Write-Host -Object "To create a release for this version, go to https://github.com/$($Repository)/releases/new?tag=$($VersionTag)&target=$(($CurrentCommit -split '/')[-1])"
        }

        [Hashtable] $VersionType = {
          <# Indicates a major version change #>
          Major = 'Major';
          <# Indicates a minor version change #>
          Minor = 'Minor';
          <# Indicates a patch version change #>
          Patch = 'Patch';
          <# Indicates no change--generally this means that the current commit is already tagged with a version #>
          None = 'None';
        }
      } Process {
        Function Resolve-CurrentCommit {
          [SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "")]
          [CmdletBinding()]
          [OutputType([PSObject])]
          Param()

          Begin {
            [PSObject] $Output = [PSObject]::new();
          } Process {
            [object] $RevParse = (git rev-parse HEAD 2>&1);

            if ($RevParse.Length -isnot [string] -or $RevParse -notmatch '^[a-f0-9]{40}$') {
              $global:RevParseError = $RevParse;
              Throw [InvalidOperationException]::new("Failed to run the command `"git rev-parse HEAD`". Get the command output at `"`$global:RevParseError`"");
            }

            [bool] $IsEmptyRepo = $False;
            [object] $IsEmptyRepoOutput = (git rev-list -n1 --all 2>&1);

            if ($IsEmptyRepoOutput.Length -isnot [string] -or $RevParse -notmatch '^[a-f0-9]{40}$') {
              $IsEmptyRepo = $True;
            }

            $Output | Add-Member -Name "RevParse" -MemberType NoteProperty -Value $RevParse;
            $Output | Add-Member -Name "IsEmptyRepo" -MemberType NoteProperty -Value $IsEmptyRepo;
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Invoke-VersionClassify {
          # [SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "")]
          [CmdletBinding()]
          [OutputType([PSObject])]
          Param(
            # Specifies a PSObject that determines the last release.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the last release.')]
            [PSObject]
            $LastRelease,
            # Specifies a PSObject that determines the set of commits in the repository.
            [Parameter(Mandatory = $True,
              HelpMessage = 'A PSObject that determines the set of commits in the repository.')]
            [PSObject]
            $CommitsSet
          )

          Begin {
            Function Get-ParsePattern {
              [CmdletBinding()]
              [OutputType([ScriptBlock])]
              Param(
                # Specifies a pattern to test against.
                [Parameter(Mandatory = $True,
                  HelpMessage = 'A pattern to test against.')]
                [string]
                $Pattern,
                # Specifies a set of flags to test against.
                [Parameter(Mandatory = $True,
                  HelpMessage = 'A set of flags to test against..')]
                [ValidatePattern('[idgs]{1,4}')]
                [string]
                $Flags,
                # Specifies the text to search against
                [Parameter(Mandatory = $True,
                  HelpMessage = 'The text to search against.')]
                [AllowEmptyString()]
                [AllowNull()]
                [string]
                $SearchBody
              )
            }
            [PSObject] $Output = [PSObject]::new();
            [string] $MajorPattern = (Get-ParsePattern -Pattern $Config.MajorPattern -Flags $Config.MajorFlags -Text $SearchBody);
            [string] $MinorPattern = (Get-ParsePattern -Pattern $Config.MinorPattern -Flags $Config.MinorFlags -Text $SearchBody);
            [bool] $EnablePrereleaseMode = $EnablePrereleaseMode;
            [string] $Type = 'None';
            [int] $Increment = 0;
            [PSObject[]] $Changed = $Null;
          } Process {
            [ScriptBlock] $RegexTester = $Null;
            If ('^\/.+\/[i]*$' -match $Pattern) {
              [int] $RegexEnd = $Pattern.LastIndexOf('/');
              [string] $ParsedFlags = $Pattern.Slice($RegexEnd + 1);
              If ([string]::IsNullOrWhiteSpace($ParsedFlags)) {
                $ParsedFlags = $Flags;
              }

              [Regex] $Regex = [Regex]::new($Pattern.Slice(1, $RegexEnd), $ParsedFlags);
              If ($SearchBody) {
                $RegexTester = {
                  Param(
                    # Specifies a PSObject containing commit information.
                    [Parameter(Mandatory = $True,
                      HelpMessage = "A PSObject containing commit information.")]
                    [PSObject]
                    $Commit
                  )

                  Return $Commit.Subject -match $Regex -or $Commit.Body -match $Regex;
                }
              } Else {
                $RegexTester = {
                  Param(
                    # Specifies a PSObject containing commit information.
                    [Parameter(Mandatory = $True,
                      HelpMessage = "A PSObject containing commit information.")]
                    [PSObject]
                    $Commit
                  )

                  Return $Commit.Subject -match $Regex;
                }
              }
            } Else {
              If ($SearchBody) {
                $RegexTester = {
                  Param(
                    # Specifies a PSObject containing commit information.
                    [Parameter(Mandatory = $True,
                      HelpMessage = "A PSObject containing commit information.")]
                    [PSObject]
                    $Commit
                  )

                  Return $Commit.Subject -match $Pattern -or $Commit.Body -match $Pattern;
                }
              } Else {
                $RegexTester = {
                  Param(
                    # Specifies a PSObject containing commit information.
                    [Parameter(Mandatory = $True,
                      HelpMessage = "A PSObject containing commit information.")]
                    [PSObject]
                    $Commit
                  )

                  Return $Commit.Subject -match $Pattern;
                }
              }
            }

            If ($CommitsSet.Commits.Length -eq 0) {
              $Changed = $CommitsSet.Changed;
            } Else {
              [PSObject[]] $Commits = $CommitsSet.Commits.Reverse();
              $Index = 1;
              For ($Commit In $Commits) {
                If ()
              }
            }

            # if (commitsSet.commits.length === 0) {
            #     return { type: VersionType.None, increment: 0, changed: commitsSet.changed };
            # }

            # const commits = commitsSet.commits.reverse();
            # let index = 1;
            # for (let commit of commits) {
            #     if (this.majorPattern(commit)) {
            #         return { type: VersionType.Major, increment: commits.length - index, changed: commitsSet.changed };
            #     }
            #     index++;
            # }

            # index = 1;
            # for (let commit of commits) {
            #     if (this.minorPattern(commit)) {
            #         return { type: VersionType.Minor, increment: commits.length - index, changed: commitsSet.changed };
            #     }
            #     index++;
            # }

            # if (this.enablePrereleaseMode && current.major === 0) {
            #     switch (Get-Content) {
            #         case VersionType.Major:
            #         return { major: current.major, minor: current.minor + 1, patch: 0 };
            #         case VersionType.Minor:
            #         case VersionType.Patch:
            #         return { major: current.major, minor: current.minor, patch: current.patch + 1 };
            #         case VersionType.None:
            #         return { major: current.major, minor: current.minor, patch: current.patch };
            #         default:
            #         throw new Error(`Unknown change type: ${type}`);
            #         }
            #     }

            #     switch (Get-Content) {
            #         case VersionType.Major:
            #         return { major: current.major + 1, minor: 0, patch: 0 };
            #         case VersionType.Minor:
            #         return { major: current.major, minor: current.minor + 1, patch: 0 };
            #         case VersionType.Patch:
            #         return { major: current.major, minor: current.minor, patch: current.patch + 1 };
            #         case VersionType.None:
            #         return { major: current.major, minor: current.minor, patch: current.patch };
            #         default:
            #         throw new Error(`Unknown change type: ${type}`);
            #     }

            # return { type: VersionType.Patch, increment: commitsSet.commits.length - 1, changed: true };

            # const { type, increment, changed } = this.resolveCommitType(commitSet);

            # const { major, minor, patch } = this.getNextVersion(lastRelease, type);

            # if (lastRelease.currentPatch !== null) {
            #     // If the current commit is tagged, we must use that version. Here we check if the version we have resolved from the
            #     // previous commits is the same as the current version. If it is, we will use the increment value, otherwise we reset
            #     // to zero. For example:

            #     // - commit 1 - v1.0.0+0
            #     // - commit 2 - v1.0.0+1
            #     // - commit 3 was tagged v2.0.0 - v2.0.0+0
            #     // - commit 4 - v2.0.1+0

            #     const versionsMatch = lastRelease.currentMajor === major && lastRelease.currentMinor === minor && lastRelease.currentPatch === patch;
            #     const currentIncrement = versionsMatch ? increment : 0;
            #     return new VersionClassification(VersionType.None, currentIncrement, false, <number>lastRelease.currentMajor, <number>lastRelease.currentMinor, <number>lastRelease.currentPatch);
            # }
          } End {
            $Output | Add-Member -Name "Type" -MemberType NoteProperty -Value $Type;
            $Output | Add-Member -Name "Increment" -MemberType NoteProperty -Value $Increment;
            $Output | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Get-VersioningTagFormatted {
          [SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "")]
          [CmdletBinding()]
          [OutputType([PSObject])]
          Param()

          Begin {
            [PSObject] $Output = [PSObject]::new();
          } Process {
            $Output | Add-Member -Name "RevParse" -MemberType NoteProperty -Value $RevParse;
            $Output | Add-Member -Name "IsEmptyRepo" -MemberType NoteProperty -Value $IsEmptyRepo;
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        Function Get-TagFormatted {
          [SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "")]
          [CmdletBinding()]
          [OutputType([string])]
          Param()

          Begin {
            [string] $Output = $Null;
          } Process {
          } End {
            Write-Output -NoEnumerate -InputObject $Output;
          }
        }

        [PSObject] $CurrentCommitResolved = (Resolve-CurrentCommit);

        If (-not $CurrentCommitResolved.IsEmptyRepo) {
          [PSObject] $LastRelease = (Resolve-LastRelease -CurrentCommit $CurrentCommitResolved -TagFormat $TagFormat);
          [PSObject] $CommitSet = (Get-Commits -LastReleaseHash $LastRelease.Hash -CurrentCommit $CurrentCommitResolved);
          [PSObject] $Classification = (Invoke-VersionClassify -LastRelease $LastRelease -CommitSet $CommitSet);

          $IsTagged = $LastRelease.IsTagged;

          $Major = $Classification.Major;
          $Minor = $Classification.Minor;
          $Patch = $Classification.Patch;
          $Increment = $Classification.Increment;
          $VersionTag = $CurrentCommitResolved.VersionTag;
          $CurrentCommit = $CurrentCommitResolved.RevParse;
          $Changed = $Classification.Changed;
          $VersionType = $Classification.VersionType;
          $PreviousVersion = (Invoke-FormatVersion -Release $LastRelease -Format '${lastRelease.major}.${lastRelease.minor}.${lastRelease.patch}');
          $FormattedVersion = (Invoke-FormatVersion -Classification $Classification -CurrentCommit $CurrentCommitResolved -Format $VersionFormat);
          [Hashtable] $AllAuthors = [ordered]@{};
          ForEach ($Commit in $CommitSet.Commits) {
            [string] $Key = "$($Commit.Author) <$($Commit.AuthorEmail)>";
            If (-not $AllAuthors.ContainsKey($Key)) {
              $AllAuthors[$Key] = [ordered]@{
                Name    = $Commit.Author;
                Email   = $Commit.AuthorEmail;
                Commits = 0
              };
            } Else {
              $AllAuthors[$Key].Commits++
            }
          }
          [Hashtable[]] $AuthorsList = @($AllAuthors.Values | Sort-Object -Property Commits -Descending);
          [string] $Authors = (Format-Users -List $AuthorsList -Format $UserFormat);
        }
      } End {
        [PSObject] $Outputs = [PSObject]::new();
        $Outputs | Add-Member -Name "Version" -MemberType NoteProperty -Value $FormattedVersion;
        $Outputs | Add-Member -Name "Major" -MemberType NoteProperty -Value $Major;
        $Outputs | Add-Member -Name "Minor" -MemberType NoteProperty -Value $Minor;
        $Outputs | Add-Member -Name "Patch" -MemberType NoteProperty -Value $Patch;
        $Outputs | Add-Member -Name "Increment" -MemberType NoteProperty -Value $Increment;
        $Outputs | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
        $Outputs | Add-Member -Name "VersionType" -MemberType NoteProperty -Value (Get-VersionType -Type $VersionType).ToLower();
        $Outputs | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
        $Outputs | Add-Member -Name "IsTagged" -MemberType NoteProperty -Value $IsTagged;
        $Outputs | Add-Member -Name "VersionTag" -MemberType NoteProperty -Value $VersionTag;
        $Outputs | Add-Member -Name "Authors" -MemberType NoteProperty -Value $Authors;
        $Outputs | Add-Member -Name "PreviousCommit" -MemberType NoteProperty -Value $PreviousCommit;
        $Outputs | Add-Member -Name "PreviousVersion" -MemberType NoteProperty -Value $PreviousVersion;
        $Outputs | Add-Member -Name "CurrentCommit" -MemberType NoteProperty -Value $CurrentCommit;
        $Outputs | Add-Member -Name "DebugOutput" -MemberType NoteProperty -Value $DebugOutput;
        $Output | Add-Member -Name "Outputs" -MemberType NoteProperty -Value $Outputs;
        Write-Output -NoEnumerate -InputObject $Output;
      }
    }

    [PSCustomObject] $SemVersion = (Get-SemanticVersion -VersionFormat $VersionFormat -ChangePath @('app', 'libs', 'submodules', 'themes'));
    # [PSCustomObject] $SemVersion = @{ Outputs = @{ Major = 1; Minor = 0; Patch = 13; Increment = 0; Commit = 'bf64670'; VersionTag = 'v1.0.13'; Version = 'v1.0.13+bf64670' }; };
    # Make (overwrite) version.xml

    Remove-Item -Force 'version.xml'
    Set-Content -LiteralPath 'version.xml' -Value (@(
        '<version>',
        "  <version>$($SemVersion.Outputs.Version)</version>",
        "  <major>$($SemVersion.Outputs.Major)</major>",
        "  <minor>$($SemVersion.Outputs.Minor)</minor>",
        "  <patch>$($SemVersion.Outputs.Patch)</patch>",
        "  <increment>$($SemVersion.Outputs.Increment)</increment>",
        "  <commit>$($SemVersion.Outputs.CurrentCommit)</commit>",
        "  <tag>$($SemVersion.Outputs.VersionTag)</tag>",
        '</version>'
      ) -join "`n");

    [bool] $SkipInstall = ($Null -ne (Get-Item -LiteralPath '.installed' -ErrorAction SilentlyContinue));

    If (-not $SkipInstall) {
      # Setup Python

      Get-ChildItem -LiteralPath $PWD -Recurse -Filter 'requirements.txt' | ForEach-Object {
        & pip install -r $_;
      }

      # Install Dependencies

      pip install -r requirements.txt -r requirements_build.txt

      # Build Actions

      $ErrorActionPreference = 'Stop';
      python distribute.py `
        --skip-pip `
        --product-version="$($SemVersion.Outputs.Major).$($SemVersion.Outputs.Minor).$($SemVersion.Outputs.Patch).$($SemVersion.Outputs.Increment)" `
        --skip-build 2>&1 | Out-Host;

      New-Item -Path .installed -ItemType File | Out-Null;
    }

    # Build
    # TODO: https://github.com/Nuitka/Nuitka-Action
    Function Invoke-NuitkaAction {
      [CmdletBinding()]
      Param(
        [Parameter(Mandatory = $True,
          HelpMessage = 'Skips install methods')]
        [bool]
        $SkipInstall,

        ### Tags for building Nuitka ###

        [Parameter(Mandatory = $False,
          HelpMessage = 'Directory to run nuitka in if not top level')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $WorkingDirectory = '.',

        [Parameter(Mandatory = $False,
          HelpMessage = 'Version of nuitka to use, branches, tags work')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $NuitkaVersion = 'main',

        [Parameter(Mandatory = $True,
          HelpMessage = 'Path to python script that is to be built.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $ScriptName,

        [Parameter(Mandatory = $False,
          HelpMessage = 'Github personal access token of an account authorized to access the Nuitka-commercial repo')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $AccessToken,

        [Parameter(Mandatory = $False,
          HelpMessage = @"
Mode in which to compile. Accelerated runs in your Python
installation and depends on it. Standalone creates a folder
with an executable contained to run it. Onefile creates a
single executable to deploy. App is onefile except on macOS
where it's not to be used. Module makes a module, and
package includes also all sub-modules and sub-packages. Dll
is currently under development and not for users yet.
Default is 'accelerated'.
"@)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Mode = 'app',

        [Parameter(Mandatory = $False,
          HelpMessage = 'Description of the file used in version information. Windows only at this time. Defaults to binary filename.')]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $FileDescription,

        [Parameter(Mandatory = $False,
          HelpMessage = @"
Include data files by filenames in the distribution. There are many
allowed forms. With '--include-data-files=/path/to/file/*.txt=folder_name/some.txt' it
will copy a single file and complain if it's multiple. With
'--include-data-files=/path/to/files/*.txt=folder_name/' it will put
all matching files into that folder. For recursive copy there is a
form with 3 values that '--include-data-files=/path/to/scan=folder_name/=**/*.txt'
that will preserve directory structure. Default empty.
"@)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $IncludeDataFiles,

        [Parameter(Mandatory = $False,
          HelpMessage = @"
Product version to use in version information. Same rules as for file version.
Defaults to unused.
"@)]
        [AllowNull()]
        [string]
        $ProductVersion
      )

      Begin {
        $env:NUITKA_CACHE_DIR = (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path 'nuitka' -ChildPath 'cache'));
        $env:PYTHON_VERSION = (((((python --version 2>&1) -split '\s+' | Select-Object -Index 1) -split '\.') | Select-Object -First 2) -join '.')
        If (-not $SkipInstall) {
          pip install -r (Join-Path -Path $PSScriptRoot -ChildPath 'requirements.txt') 2>&1 | Out-Host;

          # With commercial access token, use that repository.
          If (-not [string]::IsNullOrWhiteSpace($env:NuitkaAccessToken)) {
            $RepoUrl = "git+https://$($AccessToken)@github.com/Nuitka/Nuitka-commercial.git";
          } Else {
            $RepoUrl = "git+https://$@github.com/Nuitka/Nuitka.git"
          }

          pip install "$($RepoUrl)/@$($NuitkaVersion)#egg=nuitka" 2>&1 | Out-Host;

          if ($IsLinux) {
            sudo apt-get install -y ccache 2>&1 | Out-Host;
          }
        }
      } Process {
        $env:NUITKA_WORKFLOW_INPUTS = (@{
            'nuitka-version'                        = "$($NuitkaVersion)";
            'script-name'                           = "$($ScriptName)";
            'mode'                                  = "$($Mode)";
            'static-libpython'                      = 'auto';
            'product-version'                       = "$($ProductVersion -replace '^v', '')";
            'file-description'                      = "$($FileDescription)";
            'include-data-files'                    = "$(@($IncludeDataFiles | ForEach-Object { @($_, $_) -join '=' }) -join "`n")`n";
            'working-directory'                     = '.';
            'access-token'                          = "$($env:NuitkaAccessToken)";
            'python-flag'                           = '';
            'python-debug'                          = '';
            'enable-plugins'                        = '';
            'user-plugin'                           = '';
            'plugin-no-detection'                   = '';
            'module-parameter'                      = '';
            'include-qt-plugins'                    = '';
            'noinclude-qt-plugins'                  = '';
            'report'                                = '';
            'report-diffable'                       = '';
            'report-user-provided'                  = '';
            'report-template'                       = '';
            'quiet'                                 = '';
            'show-scons'                            = '';
            'show-memory'                           = '';
            'include-package-data'                  = '';
            'include-data-dir'                      = '';
            'noinclude-data-files'                  = '';
            'include-onefile-external-data'         = '';
            'include-raw-dir'                       = '';
            'include-package'                       = '';
            'include-module'                        = '';
            'include-plugin-directory'              = '';
            'include-plugin-files'                  = '';
            'prefer-source-code'                    = '';
            'nofollow-import-to'                    = '';
            'user-package-configuration-file'       = '';
            'onefile-tempdir-spec'                  = '';
            'onefile-child-grace-time'              = '';
            'onefile-no-compression'                = '';
            'warn-implicit-exceptions'              = '';
            'warn-unusual-code'                     = '';
            'assume-yes-for-downloads'              = 'true';
            'nowarn-mnemonic'                       = '';
            'deployment'                            = '';
            'no-deployment-flag'                    = '';
            'output-dir'                            = 'build';
            'output-file'                           = '';
            'disable-console'                       = '';
            'enable-console'                        = '';
            'company-name'                          = '';
            'product-name'                          = '';
            'file-version'                          = '';
            'copyright'                             = '';
            'trademarks'                            = '';
            'force-stdout-spec'                     = '';
            'force-stderr-spec'                     = '';
            'windows-console-mode'                  = '';
            'windows-icon-from-ico'                 = '';
            'windows-icon-from-exe'                 = '';
            'onefile-windows-splash-screen-image'   = '';
            'windows-uac-admin'                     = '';
            'windows-uac-uiaccess'                  = '';
            'macos-target-arch'                     = '';
            'macos-app-icon'                        = '';
            'macos-signed-app-name'                 = '';
            'macos-app-name'                        = '';
            'macos-app-mode'                        = '';
            'macos-sign-identity'                   = '';
            'macos-sign-notarization'               = '';
            'macos-app-version'                     = '';
            'macos-app-protected-resource'          = '';
            'linux-icon'                            = '';
            'embed-data-files-compile-time-pattern' = '';
            'embed-data-files-run-time-pattern'     = '';
            'embed-data-files-qt-resource-pattern'  = '';
            'embed-debug-qt-resources'              = '';
            'encryption-key'                        = '';
            'encrypt-stdout'                        = '';
            'encrypt-stderr'                        = '';
            'clang'                                 = '';
            'mingw64'                               = '';
            'msvc'                                  = '';
            'jobs'                                  = '';
            'lto'                                   = '';
            'cf-protection'                         = '';
            'debug'                                 = '';
            'no-debug-immortal-assumptions'         = '';
            'unstripped'                            = '';
            'trace-execution'                       = '';
            'xml'                                   = '';
            'experimental'                          = '';
            'low-memory'                            = '';
          } | ConvertTo-Json -Compress);
        $ErrorActionPreference = 'Stop';
        python -m nuitka --github-workflow-options 2>&1 | Out-Host;
      }
    }

    [string] $Mode = '';

    If ($OS -eq 'macos') {
      $Mode = 'app';
    } Else {
      $Mode = 'standalone';
    }

    Invoke-NuitkaAction -SkipInstall $SkipInstall -NuitkaVersion 'main' -ScriptName 'app/__main__.py' -Mode $Mode -FileDescription 'RimSort' -IncludeDataFiles @('version.xml') -ProductVersion $SemVersion.Outputs.VersionTag;

    # Set FILENAME
    [string] $FILENAME = $Platform;
    $FILENAME += $Arch;
    $env:FILENAME = "$FILENAME";

    [string] $OutExec = "RimSort";

    If ($IsWIndows) {
      $OutExec = "$($OutExec).exe";
    }

    # Find Executable
    [FileInfo] $Executable = (Get-ChildItem -LiteralPath . -Recurse -File -Filter $OutExec | Select-Object -First 1);
    $env:EXECUTABLE = "$Executable";
    Write-Host -Object "Executable found at $Executable";

    # Generate executable attestations
    # TODO: https://github.com/actions/attest-build-provenance
    Function Invoke-AtTestBuildProvenance {
      [CmdletBinding()]
      Param(
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $SubjectPath
      )

      Begin {
        [PSCustomObject] $Output = [PSCustomObject]::new();
      } Process {
      } End {
        Write-Output -NoEnumerate -InputObject $Output;
      }
    }

    If ($AtTest) {
      Invoke-AtTestBuildProvenance -SubjectPath $env:EXECUTABLE
    }

    # Rename new build
    Push-Location -LiteralPath build;
    Move-Item -LiteralPath $env:BUILD_OUTPUT -Destination "output";
    If ($IsWindows) {
      Compress-Archive -LiteralPath "output" -DestinationPath "$($env:FILENAME).tar";
    } Else {
      tar -cvf "$($env:FILENAME).tar" "output" 2>&1 | Out-Host;
    }
    Remove-Item -Recurse -Force -LiteralPath "output";
    Pop-Location;

    # Generate artifact attestation

    If ($AtTest -and $IsWindows) {
      Invoke-AtTestBuildProvenance -SubjectPath "./build/$($env:FILENAME).zip"
    } ElseIf ($AtTest) {
      Invoke-AtTestBuildProvenance -SubjectPath "./build/$($env:FILENAME).tar"
    }

    # Upload folder as artifact

    Function Invoke-UploadArtifact {
      [CmdletBinding()]
      Param(
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Name,
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [string]
        $Path,
        [Parameter(Mandatory = $False)]
        [ValidateNotNullOrWhiteSpace()]
        [ValidateSet('Error')]
        [string]
        $IfNoFilesFound
      )

      Begin {

      } Process {

      } End {

      }
    }

    Invoke-UploadArtifact -Name $env:FILENAME -Path "./build/$($env:FILENAME).tar" -IfNoFilesFound 'error';
  } Finally {
    $env:GitHubToken = '';
  }
} End {

} Clean {

}