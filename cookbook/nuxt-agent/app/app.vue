<script setup>
const prompt = ref('Explain Vue reactivity in two sentences.')
const reply = ref('')
const status = ref('')
const busy = ref(false)
useHead({ title: 'Nuxt agent · fx cookbook', htmlAttrs: { lang: 'en' } })

async function send() {
  busy.value = true
  reply.value = ''
  status.value = 'Replying…'
  try {
    const response = await fetch('/api/chat', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ prompt: prompt.value }),
    })
    if (!response.ok) throw new Error(response.status === 429 ? 'Request limit reached. Try again later.' : await response.text())
    for await (const text of response.body.pipeThrough(new TextDecoderStream())) reply.value += text
    status.value = 'Reply complete.'
  } catch (error) {
    status.value = error.message
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <main>
    <h1>Nuxt agent</h1>
    <p>A native libfx agent in a Nitro route. Each request starts a new conversation.</p>
    <form @submit.prevent="send">
      <label for="prompt">Prompt</label><br>
      <textarea id="prompt" v-model="prompt" name="prompt" rows="3" cols="30" required maxlength="2000" /><br>
      <button :disabled="busy">Send</button>
    </form>
    <p role="status">{{ status }}</p>
    <label for="reply">Reply</label><br>
    <textarea id="reply" :value="reply" rows="12" cols="30" readonly />
    <p><a href="https://fx.sh/docs/lib/examples#nuxt">Code and setup</a></p>
  </main>
</template>
