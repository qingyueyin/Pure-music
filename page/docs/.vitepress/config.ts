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
          { text: '交互与手势', link: '/guide/interactions' },
          { text: '外观与设置', link: '/guide/settings' }
        ]
      },
      {
        text: '社区',
        items: [
          { text: '贡献指南', link: '/guide/contribute' },
          { text: '致谢', link: '/guide/credits' },
          { text: '待办规划', link: '/guide/todo' },
          { text: '更新日志', link: '/guide/changelog' }
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
            { text: '交互与手势', link: '/guide/interactions' },
            { text: '外观与设置', link: '/guide/settings' }
          ]
        },
        {
          text: '社区',
          items: [
            { text: '贡献指南', link: '/guide/contribute' },
            { text: '致谢', link: '/guide/credits' },
            { text: '待办规划', link: '/guide/todo' },
            { text: '更新日志', link: '/guide/changelog' }
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
          svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path d="M11.985 2C6.486 2 2 6.486 2 11.985c0 4.378 2.847 8.086 6.78 9.387-.094-.82-.178-2.078.037-2.972.194-.828 1.25-5.29 1.25-5.29s-.319-.638-.319-1.582c0-1.482.86-2.59 1.93-2.59.91 0 1.35.683 1.35 1.502 0 .915-.583 2.283-.883 3.552-.251 1.062.532 1.928 1.578 1.928 1.895 0 3.352-1.998 3.352-4.88 0-2.552-1.834-4.337-4.455-4.337-3.034 0-4.815 2.276-4.815 4.627 0 .916.353 1.9.793 2.434a.32.32 0 0 1 .073.306c-.08.334-.26 1.06-.295 1.208-.047.194-.153.235-.353.141-1.32-.615-2.145-2.545-2.145-4.098 0-3.362 2.443-6.45 7.043-6.45 3.697 0 6.572 2.634 6.572 6.155 0 3.672-2.315 6.63-5.528 6.63-1.08 0-2.095-.56-2.443-1.223 0 0-.535 2.04-.665 2.538-.241.925-.89 2.084-1.325 2.79A10.02 10.02 0 0 0 11.985 22C17.514 22 22 17.514 22 11.985 22 6.486 17.514 2 11.985 2z"/></svg>'
        },
        link: 'https://gitee.com/qingyueyin/Pure-music'
      },
      {
        icon: {
          svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor"><path d="M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12 0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472-.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056-.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.91.177-.184 3.247-2.977 3.307-3.23.007-.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49-1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893-.663 3.498-1.524 5.83-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z"/></svg>'
        },
        link: 'https://t.me/+NsZamWiEKh5lOWNl'
      }
    ],
    footer: {
      message: '以 GPL-3.0 许可发布。',
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
          button: {
            buttonText: '搜索',
            buttonAriaLabel: '搜索文档'
          },
          modal: {
            displayDetails: '显示详细列表',
            resetButtonTitle: '清除搜索',
            backButtonTitle: '关闭搜索',
            noResultsText: '没有找到结果',
            footer: {
              selectText: '选择',
              selectKeyAriaLabel: '回车',
              navigateText: '切换',
              navigateUpKeyAriaLabel: '上箭头',
              navigateDownKeyAriaLabel: '下箭头',
              closeText: '关闭',
              closeKeyAriaLabel: 'Esc'
            }
          }
        }
      }
    },
    notFound: {
      code: '404',
      title: '页面不存在',
      quote: '链接可能写错了，或页面已经搬走。回首页再找找吧。',
      linkLabel: '返回首页',
      linkText: '返回首页'
    },
    darkModeSwitchLabel: '外观',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    langMenuLabel: '切换语言',
    skipToContentLabel: '跳到正文',
    docFooter: {
      prev: '上一页',
      next: '下一页'
    }
  }
})
