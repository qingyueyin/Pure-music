<template>
  <section class="download-release" aria-labelledby="download-release-title">
    <div class="download-release-main">
      <img :src="logoUrl" alt="" class="download-logo" />
      <div>
        <p class="download-kicker">当前提供</p>
        <h2 id="download-release-title">Windows 便携版</h2>
        <p class="download-description">
          解压后直接运行，配置、曲库与缓存默认保存在程序目录旁的 <code>data/</code>。
        </p>
      </div>
    </div>
    <a
      href="https://github.com/qingyueyin/Pure-music/releases"
      class="download-btn"
      target="_blank"
      rel="noreferrer"
    >
      前往下载
    </a>
  </section>
</template>

<script setup>
import { withBase } from 'vitepress'
const logoUrl = withBase('/logo.png')
</script>
