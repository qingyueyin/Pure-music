<template>
  <section class="download-release" aria-labelledby="download-release-title">
    <div class="download-release-main">
      <img :src="logoUrl" alt="" class="download-logo" />
      <div>
        <p class="download-kicker">{{ kicker }}</p>
        <h2 id="download-release-title">Windows 安装版 / 便携版</h2>
        <p class="download-description">
          安装版写入系统用户数据目录，可创建快捷方式；便携版解压即用，数据保存在程序旁
          <code>data/</code>。
        </p>
      </div>
    </div>
    <div class="download-actions">
      <a
        :href="githubUrl"
        class="download-btn"
        target="_blank"
        rel="noreferrer"
      >
        GitHub 下载
      </a>
      <a
        :href="giteeUrl"
        class="download-btn download-btn-alt"
        target="_blank"
        rel="noreferrer"
      >
        Gitee 镜像
      </a>
    </div>
    <p v-if="showGiteeHint" class="download-mirror-hint">
      GitHub 访问慢可用 Gitee；镜像同步往往较慢，版本或安装包可能暂时落后于
      GitHub，请以更新日志 / 版本号自行核对。
    </p>
  </section>
</template>

<script setup>
import { onMounted, ref, computed } from 'vue'
import { withBase } from 'vitepress'

const logoUrl = withBase('/logo.png')
const meta = ref(null)

const githubUrl = computed(
  () =>
    meta.value?.github_releases_url ||
    'https://github.com/qingyueyin/Pure-music/releases',
)
const giteeUrl = computed(
  () =>
    meta.value?.gitee_repo_url || 'https://gitee.com/qingyueyin/Pure-music',
)
const kicker = computed(() => {
  const v = meta.value?.version
  return v ? `当前最新 ${v}` : '当前提供'
})
const showGiteeHint = computed(() => meta.value?.gitee_may_lag !== false)

onMounted(async () => {
  try {
    const res = await fetch(withBase('/latest-release.json'), {
      cache: 'no-store',
    })
    if (res.ok) meta.value = await res.json()
  } catch {
    /* 无 JSON 时仍显示默认双链接 */
  }
})
</script>
