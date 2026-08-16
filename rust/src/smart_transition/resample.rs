// 低通与线性重采样。输入高于目标采样率时先低通再重采样，防混叠。

/// 二阶 Butterworth 低通状态，系数按 RBJ cookbook 归一化。
pub struct LowPassState {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl LowPassState {
    pub fn new(sample_rate: u32, cutoff_hz: f64) -> Self {
        let fs = sample_rate as f64;
        let w0 = 2.0 * std::f64::consts::PI * cutoff_hz / fs;
        let q = std::f64::consts::FRAC_1_SQRT_2;
        let alpha = w0.sin() / (2.0 * q);
        let a0 = 1.0 + alpha;
        let cos_w0 = w0.cos();
        LowPassState {
            b0: ((1.0 - cos_w0) / 2.0) / a0,
            b1: (1.0 - cos_w0) / a0,
            b2: ((1.0 - cos_w0) / 2.0) / a0,
            a1: (-2.0 * cos_w0) / a0,
            a2: (1.0 - alpha) / a0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    pub fn process(&mut self, x: f64) -> f64 {
        let y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        y
    }
}

/// 线性重采样器：输出点位置为 n * src_rate/dst_rate 的线性插值。
/// 分块 push 与一次性 push 结果一致（状态只有上一采样与相位）。
pub struct LinearResampler {
    src_rate: f64,
    dst_rate: f64,
    /// 下一输出点相对当前线段 [last, 当前输入] 的位置。
    phase: f64,
    last: f64,
    has_last: bool,
}

impl LinearResampler {
    pub fn new(src_rate: u32, dst_rate: u32) -> Self {
        assert!(src_rate > 0 && dst_rate > 0);
        LinearResampler {
            src_rate: src_rate as f64,
            dst_rate: dst_rate as f64,
            phase: 0.0,
            last: 0.0,
            has_last: false,
        }
    }

    /// 推进一批输入，返回本批产出的输出采样。
    pub fn push(&mut self, input: &[f32]) -> Vec<f32> {
        let step = self.src_rate / self.dst_rate;
        let mut out = Vec::new();
        for &s in input {
            let s = s as f64;
            if !self.has_last {
                out.push(s as f32);
                self.phase = step;
            } else {
                while self.phase <= 1.0 {
                    let t = self.phase;
                    out.push((self.last + (s - self.last) * t) as f32);
                    self.phase += step;
                }
                self.phase -= 1.0;
            }
            self.last = s;
            self.has_last = true;
        }
        out
    }
}
