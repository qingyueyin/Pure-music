<script setup>
import DefaultTheme from 'vitepress/theme'
import { computed, onMounted, onUnmounted, watch, ref } from 'vue'
import { useRoute, useData, withBase } from 'vitepress'

const { Layout } = DefaultTheme
const route = useRoute()
const { frontmatter, isDark } = useData()
const logoUrl = withBase('/logo.webp')
const heroShotUrl = computed(() =>
  withBase(isDark.value ? '/showcase/library-dark-default.webp' : '/showcase/library-light-default.webp'),
)
const loading = ref(true)

const bound = new WeakSet()
let mo
let io
let zFront = 8
let scrollCur = 0
let scrollTarget = 0
let scrollTick = 0
let smoothWheel = false

const preview = ref(null)
const previewAlt = ref('')
const previewList = ref([])
const previewIndex = ref(0)

function prefersReduced() {
  return window.matchMedia('(prefers-reduced-motion: reduce)').matches
}

function fancyDesktop() {
  return (
    !prefersReduced() &&
    window.matchMedia('(hover: hover) and (pointer: fine)').matches &&
    window.innerWidth >= 960
  )
}

function allowSmoothScroll() {
  if (!fancyDesktop()) return false
  const mem = navigator.deviceMemory
  if (typeof mem === 'number' && mem <= 4) return false
  return true
}

function onShotFront(e) {
  const el = e.currentTarget
  if (el.classList.contains('is-front')) return
  const pile = el.parentElement
  pile?.querySelectorAll('.pm-card-shot.is-front').forEach((n) => {
    n.classList.remove('is-front')
  })
  el.classList.add('is-front')
  zFront += 1
  el.style.zIndex = String(zFront)
}

function onTiltMove(e) {
  if (!fancyDesktop()) return
  const el = e.currentTarget
  const r = el.getBoundingClientRect()
  if (!r.width || !r.height) return
  const px = (e.clientX - r.left) / r.width - 0.5
  const py = (e.clientY - r.top) / r.height - 0.5
  el.style.setProperty('--rx-mouse', `${(-py * 6).toFixed(2)}deg`)
  el.style.setProperty('--ry-mouse', `${(px * 8).toFixed(2)}deg`)
}

function onTiltLeave(e) {
  e.currentTarget.style.setProperty('--rx-mouse', '0deg')
  e.currentTarget.style.setProperty('--ry-mouse', '0deg')
}

function bindShots() {
  document.querySelectorAll('.pm-card-shot').forEach((el) => {
    if (bound.has(el)) return
    bound.add(el)
    el.addEventListener('pointerenter', onShotFront)
    el.addEventListener('pointermove', onTiltMove)
    el.addEventListener('pointerleave', onTiltLeave)
  })
}

function bindScroll() {
  io?.disconnect()
  io = new IntersectionObserver(
    (entries) => {
      entries.forEach((en) => {
        if (!en.isIntersecting) return
        en.target.classList.add('is-in')
        io.unobserve(en.target)
      })
    },
    { threshold: 0.12, rootMargin: '0px 0px -8% 0px' },
  )
  document.querySelectorAll('.pm-stage, .pm-close, .pm-foot').forEach((el) => {
    const rect = el.getBoundingClientRect()
    const seen = rect.top < window.innerHeight * 0.9 && rect.bottom > 48
    if (seen) {
      requestAnimationFrame(() => el.classList.add('is-in'))
    } else {
      io.observe(el)
    }
  })
}

function collectPreviewImages() {
  return [...document.querySelectorAll('.pm-card-shot img')].filter(
    (img) => img.getAttribute('src'),
  )
}

function openPreview(img) {
  const list = collectPreviewImages()
  const i = list.indexOf(img)
  previewList.value = list.map((el) => ({
    src: el.currentSrc || el.src,
    alt: el.alt || '',
  }))
  previewIndex.value = i < 0 ? 0 : i
  const cur = previewList.value[previewIndex.value]
  preview.value = cur.src
  previewAlt.value = cur.alt
  document.body.style.overflow = 'hidden'
}

function closePreview() {
  preview.value = null
  document.body.style.overflow = ''
}

function stepPreview(dir) {
  const n = previewList.value.length
  if (!n) return
  previewIndex.value = (previewIndex.value + dir + n) % n
  const cur = previewList.value[previewIndex.value]
  preview.value = cur.src
  previewAlt.value = cur.alt
}

function onDocClick(e) {
  const img = e.target.closest?.('.pm-card-shot img')
  if (!img) return
  e.preventDefault()
  openPreview(img)
}

function onKey(e) {
  if (preview.value) {
    if (e.key === 'Escape') closePreview()
    if (e.key === 'ArrowRight') stepPreview(1)
    if (e.key === 'ArrowLeft') stepPreview(-1)
    return
  }
  if ((e.key === 'Enter' || e.key === ' ') && e.target?.classList?.contains('pm-preview')) {
    e.preventDefault()
    openPreview(e.target)
  }
}

function syncNavChrome() {
  const onHome = frontmatter.value.layout === 'home'
  const narrow = window.matchMedia('(max-width: 959.98px)').matches
  const compact = narrow || !onHome || window.scrollY >= 96
  document.documentElement.classList.toggle('pm-nav-compact', compact)
}

function onPageScroll() {
  syncNavChrome()
  if (scrollTick) return
  const y = window.scrollY
  scrollCur = y
  scrollTarget = y
  document.documentElement.style.setProperty('--pm-page-y', y.toFixed(1))
}

function onWheelSmooth(e) {
  if (!smoothWheel || preview.value) return
  if (frontmatter.value.layout !== 'home') return
  if (e.ctrlKey) return
  e.preventDefault()
  const max = Math.max(0, document.documentElement.scrollHeight - innerHeight)
  scrollTarget = Math.max(0, Math.min(max, scrollTarget + e.deltaY))
  if (!scrollTick) scrollTick = requestAnimationFrame(stepSmooth)
}

function stepSmooth() {
  scrollCur += (scrollTarget - scrollCur) * 0.28
  if (Math.abs(scrollTarget - scrollCur) < 0.4) {
    scrollCur = scrollTarget
    scrollTick = 0
  } else {
    scrollTick = requestAnimationFrame(stepSmooth)
  }
  window.scrollTo(0, scrollCur)
  document.documentElement.style.setProperty('--pm-page-y', scrollCur.toFixed(1))
  syncNavChrome()
}

function refresh() {
  bindShots()
  bindScroll()
  syncNavChrome()
  collectPreviewImages().forEach((img) => {
    img.classList.add('pm-preview')
    img.setAttribute('tabindex', '0')
    img.setAttribute('role', 'button')
  })
}

onMounted(() => {
  refresh()
  smoothWheel = allowSmoothScroll()
  document.addEventListener('click', onDocClick)
  document.addEventListener('keydown', onKey)
  window.addEventListener('scroll', onPageScroll, { passive: true })
  window.addEventListener('resize', syncNavChrome, { passive: true })
  if (smoothWheel) {
    window.addEventListener('wheel', onWheelSmooth, { passive: false })
  }
  scrollCur = window.scrollY
  scrollTarget = window.scrollY
  syncNavChrome()
  window.setTimeout(() => {
    loading.value = false
  }, 180)
  let moT
  mo = new MutationObserver(() => {
    clearTimeout(moT)
    moT = setTimeout(refresh, 80)
  })
  mo.observe(document.getElementById('app') || document.body, {
    childList: true,
    subtree: true,
  })
})

watch(
  () => route.path,
  () => {
    closePreview()
    scrollCur = 0
    scrollTarget = 0
    requestAnimationFrame(refresh)
  },
)

onUnmounted(() => {
  mo?.disconnect()
  io?.disconnect()
  document.removeEventListener('click', onDocClick)
  document.removeEventListener('keydown', onKey)
  window.removeEventListener('scroll', onPageScroll)
  window.removeEventListener('resize', syncNavChrome)
  window.removeEventListener('wheel', onWheelSmooth)
  if (scrollTick) cancelAnimationFrame(scrollTick)
  document.body.style.overflow = ''
})
</script>

<template>
  <Layout>
    <template #home-hero-image>
      <img
        class="image-src pm-hero-shot"
        :src="heroShotUrl"
        width="1920"
        height="1080"
        alt="主页"
        fetchpriority="high"
        decoding="async"
      />
    </template>
  </Layout>
  <div class="pm-loader" :class="{ out: !loading }" aria-hidden="true">
    <img :src="logoUrl" width="72" height="72" alt="" />
  </div>
  <footer class="pm-foot">
    <p class="pm-foot-note">以 GPL-3.0 许可发布 · © 2026 · Made by qingyueyin</p>
  </footer>
  <Teleport to="body">
    <div
      v-if="preview"
      class="pm-lightbox"
      role="dialog"
      aria-modal="true"
      aria-label="图片预览"
      @click.self="closePreview"
    >
      <button class="pm-lightbox-close" type="button" aria-label="关闭预览" @click="closePreview">
        关闭
      </button>
      <button
        v-if="previewList.length > 1"
        class="pm-lightbox-nav prev"
        type="button"
        aria-label="上一张"
        @click="stepPreview(-1)"
      >
        上一张
      </button>
      <img :src="preview" :alt="previewAlt" class="pm-lightbox-img" />
      <button
        v-if="previewList.length > 1"
        class="pm-lightbox-nav next"
        type="button"
        aria-label="下一张"
        @click="stepPreview(1)"
      >
        下一张
      </button>
    </div>
  </Teleport>
</template>
