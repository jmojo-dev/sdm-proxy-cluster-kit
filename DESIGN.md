# Worker kit design

The kit delivers a standalone Bash 4.2+ program to Linux systemd hosts. All three modes run from the same verified artifact. Interactive prompts read from the terminal, including when an administrator uses the paste delivery method.

## Host privileges

Root manages the administrative directory, downloads, systemd unit, environment file, backups and transcripts. The service account manages worker state in `/home/sdm/.sdm` and executes the installed CLI. Root stages administrative files under `/opt/sdm-proxy-cluster-kit`. The worker CLI lives under `/opt/strongdm/bin`. Keep those directory trees separate when modifying the installer.

## Installation

Collect the region, bind address and credentials before provisioning. Obtain CLI metadata from the selected control-plane region over HTTPS and verify the archive digest before use. Preserve the existing worker identity on repair. Verify sensitive backups before replacing a foreign service. Seal supplied credentials as the service account and require successful verification before startup. The installer preserves host SELinux enforcement.

Installation records pending work before changing the worker. A retry resumes provisioning or activates the changed files, then checks the live invocation for both worker startup and initial authsync. Managed worker updates retain unrelated settings in the systemd environment file. An existing sealed Delinea pair is reused until the operator requests rotation.

Foreign replacement keeps the original files in root-only directories on their own filesystems during the switch and records service activity and enablement links. If the candidate fails, rollback restores those files and services. The next install completes recovery after an interruption. Once the candidate passes readiness and credential checks, the installer commits its replacement history and removes the temporary copies.

## Diagnostics

Check mode inspects the worker and reports likely fixes. Live vault authentication requires an explicit choice and an independently supplied HTTPS destination. Temporary debug uses a runtime unit override and an independent systemd timer to restore the previous configuration after interruption. Debug restarts can interrupt sessions. The journal and kit transcripts may contain sensitive operational information.

## Delivery

Build the standalone script, bootstrap and paste payload from the same source. Verify the artifact against its immutable release attestation or an independently trusted digest before use. Embedded checksums protect transfers and pasted content against corruption.
