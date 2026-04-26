// Spring Physics - 弹簧物理动画系统
//
// 基于 applemusic-like-lyrics 的 spring.ts 移植。

/// Spring 参数配置
class SpringParams {
  final double mass;
  final double damping;
  final double stiffness;

  const SpringParams({
    this.mass = 1.0,
    this.damping = 10.0,
    this.stiffness = 100.0,
  });

  static const SpringParams defaultPosY = SpringParams(
    mass: 0.9,
    damping: 15,
    stiffness: 90,
  );

  static const SpringParams defaultPosX = SpringParams(
    mass: 1.0,
    damping: 10,
    stiffness: 100,
  );

  static const SpringParams defaultScale = SpringParams(
    mass: 2.0,
    damping: 25,
    stiffness: 100,
  );

  static const SpringParams backgroundLine = SpringParams(
    mass: 1.0,
    damping: 20,
    stiffness: 50,
  );

  SpringParams operator +(SpringParams other) {
    return SpringParams(
      mass: mass + other.mass,
      damping: damping + other.damping,
      stiffness: stiffness + other.stiffness,
    );
  }
}

/// 弹簧动画类 - 用于平滑的位置/缩放动画
class Spring {
  double _position = 0;
  double _velocity = 0;
  double _target = 0;
  SpringParams _params;

  bool get isAtRest => (_position - _target).abs() < 0.001 && _velocity.abs() < 0.001;

  Spring({double initialPosition = 0, SpringParams? params})
      : _position = initialPosition,
        _params = params ?? const SpringParams() {
    _target = initialPosition;
  }

  double get position => _position;
  double get velocity => _velocity;
  double get target => _target;
  SpringParams get params => _params;

  void setTargetPosition(double target, {double delay = 0}) {
    _target = target;
  }

  void setPosition(double position) {
    _position = position;
    _velocity = 0;
  }

  void setParams(SpringParams params) {
    _params = params;
  }

  double getCurrentPosition() => _position;

  void update(double dt) {
    if (isAtRest) {
      _position = _target;
      _velocity = 0;
      return;
    }

    final k = _params.stiffness;
    final m = _params.mass;
    final d = _params.damping;

    final force = -k * (_position - _target);
    final dampingForce = -d * _velocity;
    final acceleration = (force + dampingForce) / m;

    _velocity += acceleration * dt;
    _position += _velocity * dt;
  }

  void stop() {
    _velocity = 0;
  }

  void reset({double? position, double? target}) {
    if (position != null) _position = position;
    if (target != null) _target = target;
    _velocity = 0;
  }
}

/// Spring 变化参数（用于动画）
class SpringValue {
  final Spring _spring;
  double _startTime = 0;
  double _delay = 0;
  bool _active = false;

  SpringValue({double initialPosition = 0, SpringParams? params})
      : _spring = Spring(initialPosition: initialPosition, params: params);

  double get position => _spring.position;
  double get velocity => _spring.velocity;
  bool get isAtRest => _spring.isAtRest;

  void setTargetPosition(double target, {double delay = 0}) {
    _startTime = 0;
    _delay = delay;
    _active = true;
    _spring.setTargetPosition(target);
  }

  void setPosition(double position) {
    _spring.setPosition(position);
  }

  double getCurrentPosition() => _spring.getCurrentPosition();

  void setParams(SpringParams params) {
    _spring.setParams(params);
  }

  void update(double dt) {
    if (!_active) return;

    _startTime += dt;
    if (_startTime < _delay / 1000) return;

    _active = false;
    _spring.update(dt);
  }
}

/// 缓动函数
class Easing {
  static double _bezierImpl(double t, double c1, double c2, double c3, double c4) {
    final t2 = t * t;
    final t3 = t2 * t;
    final mt = 1 - t;
    final mt2 = mt * mt;

    return 3 * mt2 * t * c1 + 3 * mt * t2 * c2 + t3;
  }

  static double bezier(double x, double x1, double y1, double y2) {
    return _bezierImpl(x.clamp(0.0, 1.0), x1, y1, y2, 1.0);
  }

  static double easeIn(double t) {
    return t * t;
  }

  static double easeOut(double t) {
    return 1 - (1 - t) * (1 - t);
  }

  static double easeInOut(double t) {
    return t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) * (-2 * t + 2) / 2;
  }

  static double bezIn(double x) {
    return _bezierImpl(x.clamp(0.0, 1.0), 0.2, 0.4, 0.58, 1.0);
  }

  static final double Function(double) bezInFunc = bezIn;

  static double bezOut(double x) {
    return _bezierImpl(x.clamp(0.0, 1.0), 0.3, 0.0, 0.58, 1.0);
  }

  static final double Function(double) bezOutFunc = bezOut;

  static double makeEmpEasing(double mid, double x) {
    final beginNum = (x - 0) / mid;
    final endNum = (x - mid) / (1 - mid);
    if (x < mid) {
      return bezIn(beginNum.clamp(0.0, 1.0));
    } else {
      return 1 - bezOut(endNum.clamp(0.0, 1.0));
    }
  }

  static double makeEmpEasingMid(double x) {
    const mid = 0.5;
    return makeEmpEasing(mid, x);
  }

  static double empEasingMid(double x) {
    const mid = 0.5;
    return makeEmpEasing(mid, x);
  }
}

/// 变换数据
class LineTransforms {
  final SpringValue posY;
  final SpringValue posX;
  final SpringValue scale;

  LineTransforms({
    SpringParams? posYParams,
    SpringParams? posXParams,
    SpringParams? scaleParams,
  })  : posY = SpringValue(
          params: posYParams ?? SpringParams.defaultPosY,
        ),
        posX = SpringValue(
          params: posXParams ?? SpringParams.defaultPosX,
        ),
        scale = SpringValue(
          params: scaleParams ?? SpringParams.defaultScale,
        );

  void update(double dt) {
    posY.update(dt);
    posX.update(dt);
    scale.update(dt);
  }
}

/// 检查是否为 CJK 字符
bool isCJK(String text) {
  final code = text.codeUnitAt(0);
  return (code >= 0x4E00 && code <= 0x9FFF) ||
      (code >= 0x3400 && code <= 0x4DBF) ||
      (code >= 0x3040 && code <= 0x309F) ||
      (code >= 0x30A0 && code <= 0x30FF) ||
      (code >= 0xAC00 && code <= 0xD7AF);
}
