<template>
  <div class="download-hero">
    <div class="download-card">
      <img :src="logoUrl" alt="Pure Music" class="download-logo" />
      <h2>Pure Music</h2>
      <p class="download-version">最新版本 · Windows</p>
      <a
        href="https://github.com/qingyueyin/Pure-music/releases"
        class="download-btn"
        target="_blank"
        rel="noreferrer"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
        前往 GitHub Releases
      </a>
      <p class="download-hint">支持 Windows 10 及以上系统</p>
    </div>
  </div>
</template>

<script setup>
import { withBase } from 'vitepress'
const logoUrl = withBase('/logo.png')
</script>
