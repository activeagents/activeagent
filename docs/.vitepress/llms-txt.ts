import { readFileSync, writeFileSync } from 'fs'
import { join } from 'path'
import type { SiteConfig } from 'vitepress'

const BASE_URL = 'https://docs.activeagents.ai'

const sections = [
  {
    title: 'Getting Started',
    pages: [{ path: 'getting_started' }],
  },
  {
    title: 'Framework',
    pages: [
      { path: 'framework' },
      { path: 'agents' },
      { path: 'providers' },
      { path: 'framework/configuration' },
      { path: 'framework/instrumentation' },
      { path: 'framework/retries' },
      { path: 'framework/rails' },
      { path: 'framework/testing' },
    ],
  },
  {
    title: 'Agents',
    pages: [
      { path: 'actions' },
      { path: 'agents/generation' },
      { path: 'agents/instructions' },
      { path: 'agents/streaming' },
      { path: 'agents/callbacks' },
      { path: 'agents/error_handling' },
    ],
  },
  {
    title: 'Actions',
    pages: [
      { path: 'actions/messages' },
      { path: 'actions/embeddings' },
      { path: 'actions/tools' },
      { path: 'actions/mcps' },
      { path: 'actions/structured_output' },
      { path: 'actions/usage' },
    ],
  },
  {
    title: 'Providers',
    pages: [
      { path: 'providers/anthropic' },
      { path: 'providers/ollama' },
      { path: 'providers/open_ai' },
      { path: 'providers/open_router' },
      { path: 'providers/mock' },
    ],
  },
  {
    title: 'Examples',
    pages: [
      { path: 'examples/browser-use-agent' },
      { path: 'examples/data_extraction_agent' },
      { path: 'examples/mcp-integration-agent' },
      { path: 'examples/research-agent' },
      { path: 'examples/support-agent' },
      { path: 'examples/translation-agent' },
      { path: 'examples/web-search-agent' },
    ],
  },
  {
    title: 'Contributing',
    pages: [
      { path: 'contributing/documentation' },
      { path: 'llms_txt' },
    ],
  },
]

function parseFrontmatter(filePath: string): Record<string, string> {
  const content = readFileSync(filePath, 'utf-8')
  const match = content.match(/^---\n([\s\S]*?)\n---/)
  if (!match) return {}

  const fm: Record<string, string> = {}
  for (const line of match[1].split('\n')) {
    const m = line.match(/^(\w+):\s*(.+)$/)
    if (m) fm[m[1]] = m[2].replace(/^["']|["']$/g, '')
  }
  return fm
}

export async function generateLlmsTxt(siteConfig: SiteConfig) {
  let count = 0
  const lines: string[] = []

  lines.push('# Active Agent')
  lines.push('')
  lines.push('> ActiveAgent extends Rails MVC to AI interactions. Build intelligent agents using familiar patterns — controllers, actions, callbacks, and views. The AI framework for Rails with less code & more fun.')
  lines.push('')

  for (const section of sections) {
    lines.push(`## ${section.title}`)
    lines.push('')

    for (const page of section.pages) {
      const filePath = join(siteConfig.srcDir, `${page.path}.md`)
      let fm: Record<string, string>
      try {
        fm = parseFrontmatter(filePath)
      } catch {
        console.warn(`  skip: ${page.path}.md (not found)`)
        continue
      }

      const title = fm.title || page.path
      const desc = fm.description || ''
      const url = `${BASE_URL}/${page.path}`

      lines.push(`- [${title}](${url}): ${desc}`)
      count++
    }

    lines.push('')
  }

  const outPath = join(siteConfig.outDir, 'llms.txt')
  writeFileSync(outPath, lines.join('\n'))
  console.log(`Generated ${outPath} with ${count} entries`)
}
