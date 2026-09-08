'use client'

import { useState } from 'react'

export default function Page() {
  const [reply, setReply] = useState('')
  const [status, setStatus] = useState('')
  const [busy, setBusy] = useState(false)

  async function send(event) {
    event.preventDefault()
    const prompt = new FormData(event.currentTarget).get('prompt')
    setBusy(true)
    setReply('')
    setStatus('Replying…')
    try {
      const response = await fetch('/api/chat', {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ prompt }),
      })
      if (!response.ok) throw new Error(response.status === 429 ? 'Request limit reached. Try again later.' : await response.text())
      for await (const text of response.body.pipeThrough(new TextDecoderStream())) setReply((previous) => previous + text)
      setStatus('Reply complete.')
    } catch (error) {
      setStatus(error.message)
    } finally {
      setBusy(false)
    }
  }

  return <main>
    <h1>Next.js agent</h1>
    <p>A native libfx agent in an App Router route. Each request starts a new conversation.</p>
    <form onSubmit={send}>
      <label htmlFor="prompt">Prompt</label><br />
      <textarea id="prompt" name="prompt" rows={3} cols={30} required maxLength={2000} defaultValue="Explain server components in two sentences." /><br />
      <button disabled={busy}>Send</button>
    </form>
    <p role="status">{status}</p>
    <label htmlFor="reply">Reply</label><br />
    <textarea id="reply" rows={12} cols={30} readOnly value={reply} />
    <p><a href="https://github.com/vercel-labs/fx/blob/569025eff05b3280f2b98d480e0b95d133befda8/cookbook/README.md#run-an-example">Code and setup</a></p>
  </main>
}
