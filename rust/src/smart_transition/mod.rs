// 智能衔接：纯 Rust 分析与规划模块。
// 本文件只做模块注册，不放业务代码。

pub mod analyzer;
pub mod audible_range;
pub mod channel_fold;
pub mod config;
pub mod executor;
pub mod gain_curve;
pub mod model;
pub mod planner;
pub mod profile_store;
pub mod resample;

#[cfg(test)]
pub mod analysis_math_tests;
#[cfg(test)]
pub mod gain_curve_tests;
#[cfg(test)]
pub mod model_tests;
#[cfg(test)]
pub mod planner_tests;
#[cfg(test)]
pub mod profile_store_tests;
#[cfg(test)]
pub mod test_support;
