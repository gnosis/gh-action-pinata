# gh-action-pinata

Reusable GitHub Actions workflow to deploy static builds to **IPFS via Pinata**.

## Features

- Deploy static build directories to IPFS via Pinata
- Input validation and error handling
- Automatic retry logic for network failures
- Deployment metadata and artifact uploads
- Support for multiple build systems (npm, pnpm, yarn)
- Configurable timeouts and resource management

## Quick Start

### 1. Set up org-level secret

Create an organization secret in GitHub:
- **Settings → Secrets and variables → Actions → New organization secret**
- **Name**: `PINATA_JWT`
- **Value**: Your Pinata JWT token
- **Repository access**: Restrict to repos that need deployment

### 2. Create caller workflow

Create `.github/workflows/deploy-ipfs-dev.yml` in your application repo:

```yaml
name: Deploy to IPFS

on:
  push:
    branches: [dev, develop]

jobs:
  deploy:
    uses: <ORG>/gh-action-pinata/.github/workflows/pinata-deploy.yml@main
    with:
      environment: dev
      project_name: my-app
      build_dir: out
    secrets:
      PINATA_JWT: ${{ secrets.PINATA_JWT }}
```

## Workflow Inputs

### Required

- `environment`: Deployment environment (`dev` or `prod`)
- `project_name`: Project name (used for Pinata metadata)

### Optional

- `node_version`: Node.js version (default: `"20.15.1"`)
- `cache`: Dependency cache manager for `actions/setup-node` (`npm`, `pnpm`, or `yarn`; default: `"npm"`)
- `pinata_upload_timeout_ms`: Pinata upload HTTP request timeout in milliseconds (default: `300000`)
- `install_command`: Command to install dependencies (default: `"npm ci"`)
- `build_command`: Command to build the project (default: `"npm run build"`)
- `build_dir`: Build output directory relative to repo root (default: `"out"`)
- `caller_repository`: Override caller repository (default: caller's repo)
- `caller_ref`: Override git ref to deploy (default: caller's ref)
- `pinata_action_ref`: Git ref for pinata action repo (default: `"main"`)

### Secrets

- `PINATA_JWT` (required): Pinata JWT token

## Workflow Outputs

- `ipfs_hash`: Deployed IPFS hash
- `pinata_url`: Pinata gateway URL for the deployment

## Examples

### Basic deployment

```yaml
jobs:
  deploy:
    uses: <ORG>/gh-action-pinata/.github/workflows/pinata-deploy.yml@main
    with:
      environment: prod
      project_name: my-website
      # Optional: increase if uploads are large/slow
      pinata_upload_timeout_ms: 600000
    secrets:
      PINATA_JWT: ${{ secrets.PINATA_JWT }}
```

### Custom build system (pnpm)

```yaml
jobs:
  deploy:
    uses: <ORG>/gh-action-pinata/.github/workflows/pinata-deploy.yml@main
    with:
      environment: prod
      project_name: my-app
      cache: pnpm
      install_command: pnpm install --frozen-lockfile
      build_command: pnpm build
      build_dir: dist
    secrets:
      PINATA_JWT: ${{ secrets.PINATA_JWT }}
```

### Separate dev/prod credentials

```yaml
jobs:
  deploy:
    uses: <ORG>/gh-action-pinata/.github/workflows/pinata-deploy.yml@main
    with:
      environment: ${{ github.ref == 'refs/heads/main' && 'prod' || 'dev' }}
      project_name: my-app
    secrets:
      PINATA_JWT: ${{ github.ref == 'refs/heads/main' && secrets.PINATA_JWT_PROD || secrets.PINATA_JWT_DEV }}
```

## How It Works

1. **Checkout**: Checks out both the caller repo and this pinata action repo
2. **Build**: Installs dependencies and builds the caller repo
3. **Validate**: Validates build output exists and contains files
4. **Upload**: Uploads build directory to Pinata via IPFS (Pinata uploader deps are installed with `pnpm` using this repo’s `pnpm-lock.yaml`)
5. **IPNS** (optional): Publishes to IPNS for stable URLs
6. **Artifacts**: Uploads deployment metadata as artifacts

## Troubleshooting

### Build directory not found

**Error**: `Build directory 'caller/out' not found after build`

**Solution**: Check that your `build_command` actually creates the `build_dir`. Verify the directory name matches your build output.

### Empty build directory

**Error**: `Build directory is empty`

**Solution**: Ensure your build command produces files. Check build logs for errors.

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
- Large builds may take longer - check Pinata dashboard for upload status
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
