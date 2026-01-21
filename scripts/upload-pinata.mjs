import fs from 'node:fs'
import FormData from 'form-data'
import rfs from 'recursive-fs'
import basePathConverter from 'base-path-converter'
import got from 'got'

const PINATA_JWT = process.env.PINATA_JWT
const UPLOAD_TIMEOUT_MS = Number.parseInt(process.env.PINATA_UPLOAD_TIMEOUT_MS || '', 10) || 300000
const src = process.argv[2]
const pinName = process.argv[3]

if (!PINATA_JWT || !src || !pinName) {
  console.error('❌ Usage: PINATA_JWT=<token> node scripts/upload-pinata.mjs <build_dir> <pin_name>')
  process.exit(1)
}

// Validate source directory exists and has files
if (!fs.existsSync(src)) {
  console.error(`❌ Error: Source directory does not exist: ${src}`)
  process.exit(1)
}

const stats = fs.statSync(src)
if (!stats.isDirectory()) {
  console.error(`❌ Error: Source path is not a directory: ${src}`)
  process.exit(1)
}

async function pinDirectoryToPinata(retries = 3) {
  const url = 'https://api.pinata.cloud/pinning/pinFileToIPFS'
  
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      // Read files from source directory
      const { files } = await rfs.read(src)
      
      if (!files || files.length === 0) {
        console.error(`❌ Error: No files found in source directory: ${src}`)
        process.exit(1)
      }
      
      console.error(`📤 Uploading ${files.length} files to Pinata (attempt ${attempt}/${retries})...`)
      
      const data = new FormData()
      for (const file of files) {
        data.append('file', fs.createReadStream(file), {
          filepath: basePathConverter(src, file),
        })
      }
      data.append('pinataMetadata', JSON.stringify({ name: pinName }))

      const response = await got
        .post(url, {
          headers: {
            Authorization: `Bearer ${PINATA_JWT}`,
            ...data.getHeaders(),
          },
          body: data,
          timeout: {
            request: UPLOAD_TIMEOUT_MS,
          },
        })
        .json()

      // Validate response structure
      if (!response || !response.IpfsHash) {
        throw new Error(`Invalid response from Pinata: ${JSON.stringify(response)}`)
      }

      // Print only JSON (deploy scripts parse last line)
      console.log(JSON.stringify(response))
      return response.IpfsHash
    } catch (error) {
      const isLastAttempt = attempt === retries
      
      if (error.response) {
        // HTTP error response
        const statusCode = error.response.statusCode
        const statusMessage = error.response.statusMessage || 'Unknown error'
        const body = error.response.body || ''
        
        console.error(`❌ Pinata API error (attempt ${attempt}/${retries}):`)
        console.error(`   Status: ${statusCode} ${statusMessage}`)
        
        if (body) {
          try {
            const errorBody = JSON.parse(body)
            console.error(`   Message: ${errorBody.error?.message || errorBody.message || body}`)
          } catch {
            console.error(`   Response: ${body.substring(0, 200)}`)
          }
        }
        
        // Don't retry on auth errors
        if (statusCode === 401 || statusCode === 403) {
          console.error('❌ Authentication failed - check your PINATA_JWT token')
          process.exit(1)
        }
        
        // Don't retry on client errors (4xx) except 429 (rate limit)
        if (statusCode >= 400 && statusCode < 500 && statusCode !== 429) {
          console.error('❌ Client error - not retrying')
          process.exit(1)
        }
      } else if (error.code === 'ETIMEDOUT' || error.code === 'ECONNRESET') {
        console.error(`❌ Network error (attempt ${attempt}/${retries}): ${error.message}`)
      } else {
        console.error(`❌ Error (attempt ${attempt}/${retries}): ${error.message}`)
      }
      
      if (isLastAttempt) {
        console.error('❌ Failed to upload to Pinata after all retry attempts')
        process.exit(1)
      }
      
      // Wait before retry (exponential backoff)
      const waitTime = Math.min(1000 * Math.pow(2, attempt - 1), 10000)
      console.error(`⏳ Waiting ${waitTime}ms before retry...`)
      await new Promise(resolve => setTimeout(resolve, waitTime))
    }
  }
}

pinDirectoryToPinata()

