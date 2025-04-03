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

# cSpell:ignore uiaccess

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

                [string] $Repository = ($env:GITHUB_REPOSITORY ?? $PSScriptRoot);

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

                Function Invoke-BumpAlwaysVersionClassify {
                    [SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "")]
                    [CmdletBinding()]
                    [OutputType([PSObject])]
                    Param()

                    Begin {
                        [PSObject] $Output = [PSObject]::new();
                    } Process {
                        # if (lastRelease.currentPatch !== null) {
                        #     return new VersionClassification(VersionType.None, 0, false, <number>lastRelease.currentMajor, <number>lastRelease.currentMinor, <number>lastRelease.currentPatch);
                        # }

                        # let { major, minor, patch } = lastRelease;
                        # let type = VersionType.None;
                        # let increment = 0;

                        # if (commitSet.commits.length === 0) {
                        #     return new VersionClassification(type, 0, false, major, minor, patch);
                        # }

                        # for (let commit of commitSet.commits.reverse()) {

                        #     if (this.majorPattern(commit)) {
                        #         type = VersionType.Major;
                        #     } else if (this.minorPattern(commit)) {
                        #         type = VersionType.Minor;
                        #     } else if (this.patchPattern(commit) ||
                        #         (major === 0 && minor === 0 && patch === 0 && commitSet.commits.length > 0)) {
                        #         type = VersionType.Patch;
                        #     } else {
                        #         type = VersionType.None;
                        #     }


                        #     if (this.enablePrereleaseMode && major === 0) {
                        #         switch (type) {
                        #             case VersionType.Major:
                        #             case VersionType.Minor:
                        #                 minor += 1;
                        #                 patch = 0;
                        #                 increment = 0;
                        #                 break;
                        #             case VersionType.Patch:
                        #                 patch += 1;
                        #                 increment = 0;
                        #                 break;
                        #             default:
                        #                 increment++;
                        #                 break;
                        #         }
                        #     } else {
                        #         switch (type) {
                        #             case VersionType.Major:
                        #                 major += 1;
                        #                 minor = 0;
                        #                 patch = 0;
                        #                 increment = 0;
                        #                 break;
                        #             case VersionType.Minor:
                        #                 minor += 1;
                        #                 patch = 0;
                        #                 break;
                        #             case VersionType.Patch:
                        #                 patch += 1;
                        #                 increment = 0;
                        #                 break;
                        #             default:
                        #                 increment++;
                        #                 break;
                        #         }
                        #     }

                        # }
                        $Output | Add-Member -Name "RevParse" -MemberType NoteProperty -Value $RevParse;
                        $Output | Add-Member -Name "IsEmptyRepo" -MemberType NoteProperty -Value $IsEmptyRepo;
                    } End {
                        Write-Output -NoEnumerate -InputObject $Output;
                    }
                }

                Function Invoke-VersionClassify {
                    [SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "")]
                    [CmdletBinding()]
                    [OutputType([PSObject])]
                    Param()

                    Begin {
                        [PSObject] $Output = [PSObject]::new();
                        # this.majorPattern = this.parsePattern(config.majorPattern,config.majorFlags, searchBody);
                        # this.minorPattern = this.parsePattern(config.minorPattern,config.minorFlags, searchBody);
                        # this.enablePrereleaseMode = config.enablePrereleaseMode;
                    } Process {
                        # if (/^\/.+\/[i]*$/.test(pattern)) {
                        #     const regexEnd = pattern.lastIndexOf('/');
                        #     const parsedFlags = pattern.slice(pattern.lastIndexOf('/') + 1);
                        #     const regex = new RegExp(pattern.slice(1, regexEnd), parsedFlags || flags);
                        #     return searchBody ?
                        #         (commit: CommitInfo) => regex.test(commit.subject) || regex.test(commit.body) :
                        #         (commit: CommitInfo) => regex.test(commit.subject);
                        # } else {
                        #     const matchString = pattern;
                        #     return searchBody ?
                        #         (commit: CommitInfo) => commit.subject.includes(matchString) || commit.body.includes(matchString) :
                        #         (commit: CommitInfo) => commit.subject.includes(matchString);
                        # }

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
                        $Output | Add-Member -Name "RevParse" -MemberType NoteProperty -Value $RevParse;
                        $Output | Add-Member -Name "IsEmptyRepo" -MemberType NoteProperty -Value $IsEmptyRepo;
                    } End {
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

                $CurrentCommitResolver = (Resolve-CurrentCommit);

                If (-not $CurrentCommitResolver.IsEmptyRepo) {
                    $Major = (Resolve-CurrentCommit);
                    $Minor = (Resolve-CurrentCommit);
                    $Patch = (Resolve-CurrentCommit);
                    $Increment = (Resolve-CurrentCommit);
                    $VersionTag = (Resolve-CurrentCommit);
                    $CurrentCommit = $CurrentCommitResolver.RevParse;
                    If ($BumpEachCommit) {
                        $Version = (Invoke-BumpAlwaysVersionClassify);
                    } Else {
                        $Version = (Invoke-VersionClassify);
                    }
                }

                # const currentCommitResolver = configurationProvider.GetCurrentCommitResolver();
                # const lastReleaseResolver = configurationProvider.GetLastReleaseResolver();
                # const commitsProvider = configurationProvider.GetCommitsProvider();
                # const versionClassifier = configurationProvider.GetVersionClassifier();
                # const versionFormatter = configurationProvider.GetVersionFormatter();
                # const tagFormatter = configurationProvider.GetTagFormatter(await currentCommitResolver.ResolveBranchNameAsync());
                # const userFormatter = configurationProvider.GetUserFormatter();

                # const debugManager = DebugManager.getInstance();

                # if (await currentCommitResolver.IsEmptyRepoAsync()) {

                #     const versionInfo = new VersionInformation(0, 0, 0, 0, VersionType.None, [], false, false);
                #     return new VersionResult(
                #     versionInfo.major,
                #     versionInfo.minor,
                #     versionInfo.patch,
                #     versionInfo.increment,
                #     versionInfo.type,
                #     versionFormatter.Format(versionInfo),
                #     tagFormatter.Format(versionInfo),
                #     versionInfo.changed,
                #     versionInfo.isTagged,
                #     userFormatter.Format('author', []),
                #     '',
                #     '',
                #     tagFormatter.Parse(tagFormatter.Format(versionInfo)).join('.'),
                #     debugManager.getDebugOutput(true)
                #     );
                # }

                # const currentCommit = await currentCommitResolver.ResolveAsync();
                # const lastRelease = await lastReleaseResolver.ResolveAsync(currentCommit, tagFormatter);
                # const commitSet = await commitsProvider.GetCommitsAsync(lastRelease.hash, currentCommit);
                # const classification = await versionClassifier.ClassifyAsync(lastRelease, commitSet);

                # const { isTagged } = lastRelease;
                # const { major, minor, patch, increment, type, changed } = classification;

                # // At this point all necessary data has been pulled from the database, create
                # // version information to be used by the formatters
                # let versionInfo = new VersionInformation(major, minor, patch, increment, type, commitSet.commits, changed, isTagged);

                # // Group all the authors together, count the number of commits per author
                # const allAuthors = versionInfo.commits
                #     .reduce((acc: any, commit) => {
                #     const key = `${commit.author} <${commit.authorEmail}>`;
                #     acc[key] = acc[key] || { n: commit.author, e: commit.authorEmail, c: 0 };
                #     acc[key].c++;
                #     return acc;
                #     }, {});

                # const authors = Object.values(allAuthors)
                #     .map((u: any) => new UserInfo(u.n, u.e, u.c))
                #     .sort((a: UserInfo, b: UserInfo) => b.commits - a.commits);

                # return new VersionResult(
                #     versionInfo.major,
                #     versionInfo.minor,
                #     versionInfo.patch,
                #     versionInfo.increment,
                #     versionInfo.type,
                #     versionFormatter.Format(versionInfo),
                #     tagFormatter.Format(versionInfo),
                #     versionInfo.changed,
                #     versionInfo.isTagged,
                #     userFormatter.Format('author', authors),
                #     currentCommit,
                #     lastRelease.hash,
                #     `${lastRelease.major}.${lastRelease.minor}.${lastRelease.patch}`,
                #     debugManager.getDebugOutput()
                # );
            } End {
                $Output | Add-Member -Name "Version" -MemberType NoteProperty -Value $FormattedVersion;
                $Output | Add-Member -Name "Major" -MemberType NoteProperty -Value $Major;
                $Output | Add-Member -Name "Minor" -MemberType NoteProperty -Value $Minor;
                $Output | Add-Member -Name "Patch" -MemberType NoteProperty -Value $Patch;
                $Output | Add-Member -Name "Increment" -MemberType NoteProperty -Value $Increment;
                $Output | Add-Member -Name "VersionType" -MemberType NoteProperty -Value (Get-VersionType -Type $VersionType).ToLower();
                $Output | Add-Member -Name "Changed" -MemberType NoteProperty -Value $Changed;
                $Output | Add-Member -Name "IsTagged" -MemberType NoteProperty -Value $IsTagged;
                $Output | Add-Member -Name "VersionTag" -MemberType NoteProperty -Value $VersionTag;
                $Output | Add-Member -Name "Authors" -MemberType NoteProperty -Value $Authors;
                $Output | Add-Member -Name "PreviousCommit" -MemberType NoteProperty -Value $PreviousCommit;
                $Output | Add-Member -Name "PreviousVersion" -MemberType NoteProperty -Value $PreviousVersion;
                $Output | Add-Member -Name "CurrentCommit" -MemberType NoteProperty -Value $CurrentCommit;
                $Output | Add-Member -Name "DebugOutput" -MemberType NoteProperty -Value $DebugOutput;
                Write-Output -NoEnumerate -InputObject $Output;
            }
        }

        # [PSCustomObject] $SemVersion = (Get-SemanticVersion -VersionFormat $VersionFormat -ChangePath @('app', 'libs', 'submodules', 'themes'));
        [Hashtable] $SemVersion = @{ Outputs = @{ Major = 1; Minor = 0; Patch = 13; Increment = 0; Commit = 'bf64670'; Tag = 'v1.0.13'; Version = 'v1.0.13+bf64670' }; };
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

        # Setup Python

        Get-ChildItem -LiteralPath $PWD -Recurse -Filter 'requirements.txt' | ForEach-Object {
            #& pip install -r $_;
        }

        # Install Dependencies

        #pip install -r requirements.txt -r requirements_build.txt

        # Build Actions

        $ErrorActionPreference = 'Stop';
        python distribute.py `
            --skip-pip `
            --product-version="$($SemVersion.Outputs.Major).$($SemVersion.Outputs.Minor).$($SemVersion.Outputs.Patch).$($SemVersion.Outputs.Increment)" `
            --skip-build 2>&1 | Out-Host;

        # Build
        # TODO: https://github.com/Nuitka/Nuitka-Action
        Function Invoke-NuitkaAction {
            [CmdletBinding()]
            Param(
                [Parameter(Mandatory = $False)]
                [ValidateNotNullOrWhiteSpace()]
                [string]
                $NuitkaVersion = "main",
                [Parameter(Mandatory = $True)]
                [ValidateNotNullOrWhiteSpace()]
                [string]
                $ScriptName,
                [Parameter(Mandatory = $False)]
                [ValidateNotNullOrWhiteSpace()]
                [string]
                $Mode = "app",
                [Parameter(Mandatory = $False)]
                [ValidateNotNullOrWhiteSpace()]
                [string]
                $FileDescription,
                [Parameter(Mandatory = $False)]
                [ValidateNotNullOrEmpty()]
                [string[]]
                $IncludeDataFiles,
                [Parameter(Mandatory = $False)]
                [ValidateNotNullOrEmpty()]
                [string]
                $VersionTag
            )

            Begin {
                $env:NUITKA_CACHE_DIR = (Join-Path -Path $PSScriptRoot -ChildPath (Join-Path -Path 'nuitka' -ChildPath 'cache'));
                $env:PYTHON_VERSION = (((((python --version 2>&1) -split '\s+' | Select-Object -Index 1) -split '\.') | Select-Object -First 2) -join '.')
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
            } Process {
                $env:NUITKA_WORKFLOW_INPUTS = (@{
                        'nuitka-version'                        = "$($NuitkaVersion)";
                        'script-name'                           = "$($ScriptName)";
                        'mode'                                  = "$($Mode)";
                        'static-libpython'                      = 'auto';
                        'product-version'                       = "$($VersionTag -replace '^v', '')";
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

        Invoke-NuitkaAction -NuitkaVersion 'main' -ScriptName 'app/__main__.py' -Mode $Mode -FileDescription 'RimSort' -IncludeDataFiles @('version.xml=version.xml') -VersionTag $SemVersion.Outputs.VersionTag;

        # Set FILENAME
        [string] $FILENAME = $Platform;
        $FILENAME += $Arch;
        $env:FILENAME = "$FILENAME";

        # Find Executable
        [FileInfo] $Executable = $(Get-ChildItem -LiteralPath . -Recurse -File -Filter $Executable | Select-Object -First 1);
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
        tar -cvf "$($env:FILENAME).tar" "output" 2>&1;
        Remove-Item -Recurse -Force -LiteralPath "output";
        Pop-Location;

        # Generate artifact attestation

        If ($AtTest) {
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
    } Catch {
        Throw;
    } Finally {
        $env:GitHubToken = '';
    }
} End {

} Clean {

}