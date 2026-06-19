# gh-action-pinata

Reusable GitHub Actions workflow to deploy **prebuilt** static files to **IPFS via Pinata**.

This workflow is **deploy-only**: you build your app in your own job, upload the
output as an artifact, then call this workflow to publish that artifact to IPFS.
It does not check out or build your repo.

## Features

- Deploy a prebuilt artifact to IPFS via Pinata
- Input validation and error handling
- Automatic retry logic for network failures
- Deployment metadata and artifact uploads
- Post-deploy health checks across multiple IPFS gateways
- Job summary with access URLs and both CIDv0 and CIDv1
- Configurable timeouts and resource management

## Quick Start

### 1. Set up org-level secret

Create an organization secret in GitHub:
- **Settings → Secrets and variables → Actions → New organization secret**
- **Name**: `PINATA_JWT`
- **Value**: Your Pinata JWT token
- **Repository access**: Restrict to repos that need deployment

### 2. Create caller workflow

In your application repo, build the app in one job and call this workflow in a
dependent job. The deploy job downloads the artifact uploaded by the build job
(both jobs must be in the **same workflow run**).

```yaml
name: Deploy to IPFS

on:
  push:
    branches: [dev, develop]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 24
      - run: npm ci && npm run build   # use whatever toolchain you like
      - uses: actions/upload-artifact@v4
        with:
          name: site-build
          path: out                    # your build output directory

  deploy:
    needs: build
    uses: <ORG>/gh-action-pinata/.github/workflows/pinata-deployment.yml@main
    with:
      environment: dev
      project_name: my-app
      build_artifact_name: site-build
      build_dir: out
    secrets:
      PINATA_JWT: ${{ secrets.PINATA_JWT }}
```

> The build job is entirely yours — any language, package manager, or toolchain.
> This workflow only consumes the resulting artifact.

## Workflow Inputs

### Required

- `environment`: Deployment environment (`dev` or `prod`)
- `project_name`: Project name (used for Pinata metadata)
- `build_artifact_name`: Name of the prebuilt artifact (uploaded earlier in the same run) to deploy

### Optional

- `pinata_upload_timeout_ms`: Pinata upload HTTP request timeout in milliseconds (default: `300000`)
- `build_dir`: Directory the artifact is extracted into and deployed from (default: `"out"`)
- `pinata_action_repository`: Repo to source this action from (default: `"gnosis/gh-action-pinata"`)
- `pinata_action_ref`: Git ref for pinata action repo (default: `"main"`)
- `health_check`: Run post-deploy gateway health checks (default: `true`)

### Secrets

- `PINATA_JWT` (required): Pinata JWT token

## Workflow Outputs

- `ipfs_hash`: Deployed IPFS hash (CIDv0)
- `pinata_url`: Dedicated gateway URL for the deployment (`https://gnosis.mypinata.cloud/ipfs/<hash>/`)

## Deployment Summary

On success the workflow writes a job summary containing:

- **Primary access URL**: the dedicated Pinata gateway (`gnosis.mypinata.cloud`)
- **Alternative gateways**: public IPFS gateways (`ipfs.io`, `dweb.link`)
- **Both CIDs**: CIDv0 (`Qm…`) and CIDv1 (`bafy…`)

The gateway list is owned by [`scripts/deploy-to-pinata.sh`](scripts/deploy-to-pinata.sh) — edit the `IPFS_GATEWAYS` array there to change which gateways are used and reported.

## Examples

### Larger uploads

```yaml
jobs:
  deploy:
    needs: build
    uses: <ORG>/gh-action-pinata/.github/workflows/pinata-deployment.yml@main
    with:
      environment: prod
      project_name: my-website
      build_artifact_name: site-build
      # Optional: increase if uploads are large/slow
      pinata_upload_timeout_ms: 600000
    secrets:
      PINATA_JWT: ${{ secrets.PINATA_JWT }}
```

### Separate dev/prod credentials

```yaml
jobs:
  deploy:
    needs: build
    uses: <ORG>/gh-action-pinata/.github/workflows/pinata-deployment.yml@main
    with:
      environment: ${{ github.ref == 'refs/heads/main' && 'prod' || 'dev' }}
      project_name: my-app
      build_artifact_name: site-build
    secrets:
      PINATA_JWT: ${{ github.ref == 'refs/heads/main' && secrets.PINATA_JWT_PROD || secrets.PINATA_JWT_DEV }}
```

## How It Works

1. **Checkout**: Checks out this pinata action repo (for the uploader scripts)
2. **Download**: Downloads the prebuilt artifact (`build_artifact_name`) into `build_dir`
3. **Validate**: Validates the extracted directory exists and contains files
4. **Upload**: Uploads the directory to Pinata via IPFS (uploader deps installed with `pnpm` using this repo’s `pnpm-lock.yaml`)
5. **Health check** (optional): Verifies the deployment is reachable across gateways
6. **Artifacts**: Uploads deployment metadata as artifacts

## Troubleshooting

### Artifact directory not found

**Error**: `Artifact directory 'out' not found after download`

**Solution**: Confirm the build job ran `upload-artifact` with a `name` matching `build_artifact_name`, and that both jobs are in the same workflow run (the deploy job uses `needs:` on the build job).

### Empty artifact directory

**Error**: `Artifact directory is empty`

**Solution**: Ensure your build job produced files and uploaded the correct `path`. Check the build job logs.

### Pinata authentication failed

**Error**: `Authentication failed - check your PINATA_JWT token`

**Solution**: 
- Verify your `PINATA_JWT` secret is set correctly
- Check token hasn't expired
- Ensure token has pinning permissions in Pinata

### Network timeout

**Error**: `Network error` or `ETIMEDOUT`

**Solution**: 
- The workflow includes automatic retries with exponential backoff
- Large uploads may take longer - check Pinata dashboard for upload status, or raise `pinata_upload_timeout_ms`
- Verify network connectivity from GitHub Actions

### Invalid IPFS hash

**Error**: `Invalid or missing IPFS hash`

**Solution**: 
- Check Pinata API response in workflow logs
- Verify Pinata service status
- Check for rate limiting (429 errors)

## Security Considerations

- **Secrets**: Never commit `PINATA_JWT` to repositories
- **Input validation**: Project names are sanitized to prevent path traversal
- **Error handling**: Sensitive information is not exposed in logs
- **Timeouts**: All operations have reasonable timeouts to prevent hanging

## Limitations

- **File size**: Subject to Pinata API limits
- **Rate limits**: Subject to Pinata API rate limits (automatic retries help)
