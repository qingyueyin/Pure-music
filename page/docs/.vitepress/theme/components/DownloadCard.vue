<template>
  <section
    class="download-release"
    aria-labelledby="download-release-title"
    :aria-busy="status === 'loading' ? 'true' : undefined"
  >
    <div class="download-release-main">
      <img :src="logoUrl" alt="" class="download-logo" width="52" height="52" />
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
        :href="installerHref"
        class="download-btn"
        target="_blank"
        rel="noreferrer"
      >
        {{ installerLabel }}
      </a>
      <a
        :href="portableHref"
        class="download-btn download-btn-alt"
        target="_blank"
        rel="noreferrer"
      >
        {{ portableLabel }}
      </a>
      <a
        :href="githubUrl"
        class="download-all"
        target="_blank"
        rel="noreferrer"
      >
        全部版本
      </a>
    </div>
    <p v-if="status === 'error'" class="download-mirror-hint" role="status">
      未能读取版本信息，已指向 GitHub Releases。
    </p>
    <p v-else-if="showGiteeHint" class="download-mirror-hint">
      GitHub 访问慢可用
      <a :href="giteeUrl" target="_blank" rel="noreferrer">Gitee 镜像</a>；镜像同步往往较慢，版本或安装包可能暂时落后，请以更新日志 / 版本号自行核对。
    </p>
  </section>
</template>

<script setup>
import { onMounted, ref, computed } from 'vue'
import { withBase } from 'vitepress'

const logoUrl = withBase('/logo.webp')
const meta = ref(null)
const status = ref('loading')

const githubUrl = computed(
  () =>
    meta.value?.github_release_url ||
    meta.value?.github_releases_url ||
    'https://github.com/qingyueyin/Pure-music/releases',
)
const giteeUrl = computed(
  () =>
    meta.value?.gitee_releases_url ||
    meta.value?.gitee_repo_url ||
    'https://gitee.com/qingyueyin/Pure-music',
)
const installerHref = computed(
  () => meta.value?.installer_url || githubUrl.value,
)
const portableHref = computed(
  () => meta.value?.portable_url || githubUrl.value,
)
const installerLabel = computed(() =>
  meta.value?.installer_url ? '下载安装版' : 'GitHub 下载',
)
const portableLabel = computed(() =>
  meta.value?.portable_url ? '下载便携版' : '打开发布页',
)
const kicker = computed(() => {
  if (status.value === 'loading') return '正在读取版本'
  const v = meta.value?.version
  return v ? `当前最新 ${v}` : '当前提供'
})
const showGiteeHint = computed(() => meta.value?.gitee_may_lag !== false)

onMounted(async () => {
  try {
    const res = await fetch(withBase('/latest-release.json'), {
      cache: 'no-store',
    })
    if (!res.ok) {
      status.value = 'error'
      return
    }
    meta.value = await res.json()
    status.value = 'ready'
  } catch {
    status.value = 'error'
  }
})
</script>
