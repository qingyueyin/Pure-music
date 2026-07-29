import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Pure Music',
  description: 'Windows 本地音乐播放器',
  base: '/Pure-music/',
  lang: 'zh-CN',
  head: [
    ['link', { rel: 'icon', href: '/Pure-music/logo.png' }],
    ['link', { rel: 'apple-touch-icon', href: '/Pure-music/logo.png' }],
    ['meta', { name: 'theme-color', content: '#BDA12F' }]
  ],
  appearance: true,
  themeConfig: {
    logo: '/logo.png',
    siteTitle: 'Pure Music',
    nav: [
      { text: '首页', link: '/' },
      {
        text: '指南',
        items: [
          { text: '简介', link: '/guide/' },
          { text: '安装', link: '/guide/install' },
          { text: '快速上手', link: '/guide/quickstart' },
          { text: '常见问题', link: '/guide/faq' }
        ]
      },
      {
        text: '功能',
        items: [
          { text: '音乐库', link: '/guide/library' },
          { text: '播放与音频', link: '/guide/playback' },
          { text: '歌词', link: '/guide/lyrics' },
          { text: '桌面歌词', link: '/guide/desktop-lyric' },
          { text: '外观与设置', link: '/guide/settings' }
        ]
      },
      {
        text: '社区',
        items: [
          { text: '贡献指南', link: '/guide/contribute' },
          { text: '致谢', link: '/guide/credits' }
        ]
      },
      {
        text: '开发',
        items: [
          { text: '架构', link: '/dev/' },
          { text: '构建', link: '/dev/build' }
        ]
      },
      { text: '下载', link: '/download' }
    ],
    sidebar: {
      '/guide/': [
        {
          text: '开始',
          items: [
            { text: '简介', link: '/guide/' },
            { text: '安装', link: '/guide/install' },
            { text: '快速上手', link: '/guide/quickstart' }
          ]
        },
        {
          text: '功能',
          items: [
            { text: '音乐库', link: '/guide/library' },
            { text: '播放与音频', link: '/guide/playback' },
            { text: '歌词', link: '/guide/lyrics' },
            { text: '桌面歌词', link: '/guide/desktop-lyric' },
            { text: '外观与设置', link: '/guide/settings' }
          ]
        },
        {
          text: '社区',
          items: [
            { text: '贡献指南', link: '/guide/contribute' },
            { text: '致谢', link: '/guide/credits' }
          ]
        },
        {
          text: '帮助',
          items: [
            { text: '常见问题', link: '/guide/faq' },
            { text: '快捷键', link: '/guide/hotkeys' }
          ]
        }
      ],
      '/dev/': [
        {
          text: '开发',
          items: [
            { text: '架构', link: '/dev/' },
            { text: '构建', link: '/dev/build' }
          ]
        }
      ]
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/qingyueyin/Pure-music' },
      {
        icon: {
          svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z"/></svg>'
        },
        link: 'https://t.me/+NsZamWiEKh5lOWNl'
      }
    ],
    footer: {
      message: 'Released under the GPL-3.0 License.',
      copyright: '© 2026 Pure Music · Made by qingyueyin'
    },
    outline: {
      label: '本页目录',
      level: [2, 3]
    },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '搜索', buttonAriaLabel: '搜索' },
          modal: {
            noResultsText: '没有找到结果',
            resetButtonTitle: '清除',
            footer: { selectText: '选择', navigateText: '切换', closeText: '关闭' }
          }
        }
      }
    },
    darkModeSwitchLabel: '外观',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    docFooter: {
      prev: '上一页',
      next: '下一页'
    }
  }
})
