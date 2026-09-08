import { createFxAgent, supportsJspi } from 'libfx/browser'
import { model } from '../shared/model.mjs'

const form = document.querySelector('form')
const button = document.querySelector('button')
const reply = document.querySelector('#reply')
const status = document.querySelector('#status')
let agent

if (!supportsJspi()) {
  status.textContent = 'This browser does not support WebAssembly JSPI. Try a current version of Chrome or Edge.'
  button.disabled = true
}

form.addEventListener('submit', async (event) => {
  event.preventDefault()
  button.disabled = true
  reply.value = ''
  status.textContent = 'Replying…'
  try {
    agent ??= await createFxAgent({
      apiKey: 'demo', model,
      fetch(url, init) {
        const path = new URL(url).pathname
        return fetch(`/api/gateway?path=${encodeURIComponent(path)}`, init)
      },
    })
    const turn = agent.prompt(new FormData(form).get('prompt'))
    for await (const event of turn) {
      if (event.type === 'text_delta') reply.value += event.delta
    }
    await turn.result
    status.textContent = 'Reply complete.'
  } catch (error) {
    status.textContent = error.message
  } finally {
    button.disabled = false
  }
})

window.addEventListener('pagehide', () => { void agent?.close() })
