import 'dart:async';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:orchid/api/orchid_types.dart';
import 'package:orchid/api/preferences/user_preferences.dart';
import 'package:orchid/generated/l10n.dart';
import 'package:orchid/pages/app_text.dart';
import 'package:orchid/api/notifications.dart';
import 'package:orchid/pages/common/formatting.dart';
import 'package:orchid/pages/common/gradients.dart';
import 'package:orchid/api/orchid_api.dart';
import 'package:orchid/pages/app_colors.dart';
import 'package:orchid/pages/connect/welcome_panel.dart';

import '../app_routes.dart';

/// The main page containing the connect button.
class ConnectPage extends StatefulWidget {
  final ValueNotifier<Color> appBarColor;
  final ValueNotifier<Color> iconColor;

  ConnectPage({Key key, @required this.appBarColor, @required this.iconColor})
      : super(key: key);

  @override
  _ConnectPageState createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage>
    with TickerProviderStateMixin {
  // Current state reflected by the page, driving color and animation.
  OrchidConnectionState _connectionState = OrchidConnectionState.NotConnected;

  // Animation controller for transitioning to the connected state
  AnimationController _connectAnimController;

  //AnimationController _highlightAnimationController;

  // Animations driven by the connected state
  Animation<LinearGradient> _backgroundGradient;
  Animation<Color> _iconColor;

  bool _hasConfiguredHops = false;

  bool get _showWelcomePane => !_hasConfiguredHops;

  List<StreamSubscription> _rxSubscriptions = List();

  @override
  void initState() {
    super.initState();
    _initListeners();
    _initAnimations();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        // background gradient
        _buildBackgroundGradient(),

        // The page content including the button title, button, and route info when connected.
        SafeArea(
          child: _buildPageContent(),
        ),

        // The welcome panel
        if (_showWelcomePane)
          SafeArea(
            child: Container(
              alignment: Alignment.bottomCenter,
              child: WelcomePanel(),
              //child: Container(color: Colors.orange, width: 50, height: 50),
            ),
          )
      ],
    );
  }

  /// The page content including the button title, button, and route info when connected.
  Widget _buildPageContent() {
    return Column(
      children: <Widget>[
        // Line art background, logo, and connect button
        Expanded(
          flex: 10,
          child: _buildCenterControls(),
        ),

        pady(50),
        _buildManageProfileButton(),

        pady(20),
        _buildStatusMessage(context),

        Spacer(flex: 2),
      ],
    );
  }

  Padding _buildManageProfileButton() {
    var textColor = Colors.white;
    var bgColor = AppColors.purple_3;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 300),
        child: Container(
          height: 50,
          width: double.infinity,
          child: RaisedButton(
              elevation: 0,
              color: bgColor,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24))),
              onPressed: () {
                Navigator.pushNamed(context, AppRoutes.circuit);
              },
              child: Text(
                "Manage Profile",
                style: TextStyle(color: textColor, fontSize: 16),
              )),
        ),
      ),
    );
  }

  Widget _buildCenterControls() {
    return Container(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Line art background
          OrientationBuilder(
            builder: (BuildContext context, Orientation orientation) {
              return SvgPicture.asset(
                "assets/svg/line_art.svg",
                width: double.infinity,
                alignment: orientation == Orientation.landscape
                    ? Alignment.topCenter
                    : Alignment.center,
                fit: orientation == Orientation.landscape
                    ? BoxFit.fitWidth
                    : BoxFit.contain,
              );
            },
          ),
          // Large logo and connect button
          Padding(
            // Logo is asymmetric, shift left a bit
            padding: const EdgeInsets.only(right: 9.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildLogo(),
                pady(48),
//              if (_connectionState == OrchidConnectionState.Connecting ||
//                  _connectionState == OrchidConnectionState.Disconnecting)
//                AnimatedBuilder(
//                    animation: _highlightAnimationController,
//                    builder: (context, snapshot) {
//                      return _buildConnectButton();
//                    })
//              else
                Padding(
                  // Logo is asymmetric, shift right a bit
                  padding: const EdgeInsets.only(left: 18.0),
                  child: _buildConnectButton(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    print("build logo, connection state = ${_connectionState}");
    var image = () {
      return Image.asset("assets/images/connect_logo.png",
          width: 207, height: 186); // match glow image size
    };
    var glowImage = () {
      return Image.asset("assets/images/logo_glow.png",
          width: 207, height: 186);
    };

    var transitionImage = () {
      return ShaderMask(
          shaderCallback: (rect) {
            return _buildTransitionGradient().createShader(rect);
          },
          blendMode: BlendMode.srcATop,
          child: image());
    };

    /* Attempt to build the glow image dynamically... Need a way to blend.
    var glowLogo = ShaderMask(
      shaderCallback: (rect) {
        return _buildGlowGradient().createShader(rect);
      },
      blendMode: BlendMode.srcATop,
      child: image,
    );

    var blurLogo = ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
      child: image,
    );

    return Stack(
      children: [
        glowLogo,
        blurLogo,
      ],
    );
     */

    switch (_connectionState) {
      case OrchidConnectionState.Invalid:
      case OrchidConnectionState.NotConnected:
        return image();
      case OrchidConnectionState.Connecting:
      case OrchidConnectionState.Disconnecting:
        return transitionImage();
      case OrchidConnectionState.Connected:
        return glowImage();
    }
    throw Exception();
  }

  Widget _buildConnectButton() {
    var textColor = Colors.white;
    var bgColor = AppColors.purple_3;
    var gradient;
    String text;
    switch (_connectionState) {
      case OrchidConnectionState.Disconnecting:
        text = "Disconnecting";
        gradient = _buildTransitionGradient();
        break;
      case OrchidConnectionState.Connecting:
        text = "Connecting";
        gradient = _buildTransitionGradient();
        break;
      case OrchidConnectionState.Invalid:
      case OrchidConnectionState.NotConnected:
        text = "Connect";
        break;
      case OrchidConnectionState.Connected:
        textColor = AppColors.purple_3;
        bgColor = AppColors.teal_5;
        text = "Disconnect";
    }

    // Enable the connect button when there is a circuit.
    // Don't disable it if we are already connected (corner case).
    bool buttonEnabled = _hasConfiguredHops ||
        _connectionState == OrchidConnectionState.Connecting ||
        _connectionState == OrchidConnectionState.Connected;
    if (!buttonEnabled) {
      bgColor = AppColors.neutral_4;
    }

    // Rounded flat button supporting gradient with ink effect that works over it
    return FlatButton(
      onPressed: buttonEnabled ? _onConnectButtonPressed : null,
      textColor: Colors.white,
      padding: const EdgeInsets.all(0.0),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24))),
      child: Ink(
        decoration: new BoxDecoration(
          color: bgColor,
          gradient: gradient,
          borderRadius: BorderRadius.all(Radius.circular(24.0)),
        ),
        child: Container(
          width: 150,
          height: 48,
          padding: const EdgeInsets.all(12.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.power_settings_new, color: textColor, size: 24),
              padx(4),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: textColor, fontSize: 16),
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Gradient _buildTransitionGradient() {
    return LinearGradient(
//        begin: Alignment(0, -1 + _highlightAnimationController.value ?? 0),
//        end: Alignment(0, 1 + _highlightAnimationController.value ?? 0),
        begin: Alignment(0.15, -1.0),
        end: Alignment(0, 1),
        colors: [AppColors.teal_4, AppColors.purple_3],
        tileMode: TileMode.clamp);
  }

  Gradient _buildGlowGradient() {
    return LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xffE8DDFD), Color(0xffB88DFC), Color(0xff8C61E1)],
        tileMode: TileMode.clamp);
  }

//  background: linear-gradient(180deg, #E8DDFD 0%, #B88DFC 56.26%, #8C61E1 100%);

  Widget _buildBackgroundGradient() {
    return AnimatedBuilder(
      animation: _connectAnimController,
      builder: (context, child) => Container(
        decoration: BoxDecoration(gradient: _backgroundGradient.value),
      ),
    );
  }

  // TODO: This will be driven by the tunnel status messages when available
  Widget _buildStatusMessage(BuildContext context) {
    // Localize
    String message;
    switch (_connectionState) {
      case OrchidConnectionState.Disconnecting:
        message = s.orchidDisconnecting;
        break;
      case OrchidConnectionState.Connecting:
        message = s.orchidConnecting;
        break;
      case OrchidConnectionState.Invalid:
      case OrchidConnectionState.NotConnected:
        message = s.pushToConnect;
        break;
      case OrchidConnectionState.Connected:
        message = s.orchidIsRunning;
    }

    Color color =
        _showConnectedBackground() ? AppColors.neutral_6 : AppColors.neutral_1;

    return Container(
      // Note: the emoji changes the baseline so we give this a couple of pixels
      // Note: of extra hieght and bottom align it.
      height: 32.0,
      alignment: Alignment.bottomCenter,
      child: Text(message,
          textAlign: TextAlign.center,
          style: AppText.connectButtonMessageStyle.copyWith(color: color)),
    );
  }

  /// Listen for changes in Orchid network status.
  void _initListeners() {
    OrchidAPI().logger().write("Connect Page: Init listeners...");

    // Monitor VPN permission status
    /*
    _rxSubscriptions
        .add(OrchidAPI().vpnPermissionStatus.listen((bool installed) {
      OrchidAPI().logger().write("VPN Perm status changed: $installed");
      if (!installed) {
        //var route = AppTransitions.downToUpTransition(
        //OnboardingVPNPermissionPage(allowSkip: false));
        //Navigator.push(context, route);
        Navigator.push(context, MaterialPageRoute(builder: (context) =>
                    OnboardingVPNPermissionPage(allowSkip: false)));
      }
    }));
     */

    // Monitor connection status
    _rxSubscriptions
        .add(OrchidAPI().connectionStatus.listen((OrchidConnectionState state) {
      OrchidAPI()
          .logger()
          .write("[connect page] Connection status changed: $state");
      _connectionStateChanged(state);
    }));

    _rxSubscriptions.add(AppNotifications().notification.listen((_) {
      setState(() {}); // Trigger refresh of the UI
    }));

    // TODO: The circuit really should be observable directly via OrchidAPI
    _rxSubscriptions
        .add(OrchidAPI().circuitConfigurationChanged.listen((value) {
      _updateWelcomePane();
    }));
  }

  // TODO: The circuit really should be observable directly via OrchidAPI
  void _updateWelcomePane() async {
    _hasConfiguredHops = (await UserPreferences().getCircuit()).hops.isNotEmpty;
    setState(() {});
  }

  /// Called upon a change to Orchid connection state
  void _connectionStateChanged(OrchidConnectionState state) {
    // Fade the background animation in or out based on which direction we are going.
    var fromConnected = _showConnectedBackground();
    var toConnected = _showConnectedBackgroundFor(state);

    if (toConnected && !fromConnected) {
      _connectAnimController.forward().then((_) {});
    }
    if (fromConnected && !toConnected) {
      _connectAnimController.reverse().then((_) {});
    }
    _connectionState = state;
    if (mounted) {
      setState(() {});
    }
  }

  /// True if we show the animated connected background for the given state.
  bool _showConnectedBackgroundFor(OrchidConnectionState state) {
    switch (state) {
      case OrchidConnectionState.Invalid:
      case OrchidConnectionState.NotConnected:
      case OrchidConnectionState.Connecting:
        return false;
      case OrchidConnectionState.Connected:
      case OrchidConnectionState.Disconnecting:
        return true;
    }
    throw Exception();
  }

  /// True if we show the animated connected background for the current state.
  bool _showConnectedBackground() {
    return _showConnectedBackgroundFor(_connectionState);
  }

  /// Set up animations
  void _initAnimations() {
    _connectAnimController = AnimationController(
        duration: const Duration(milliseconds: 1000), vsync: this);

    // The background gradient
    var backgroundGradientDisconnected =
        VerticalLinearGradient(colors: [AppColors.white, AppColors.grey_6]);
    var backgroundGradientConnected = VerticalLinearGradient(
        colors: [AppColors.purple_3, AppColors.purple_1]);
    _backgroundGradient = LinearGradientTween(
            begin: backgroundGradientDisconnected,
            end: backgroundGradientConnected)
        .animate(_connectAnimController);

    // Update the app bar color to match the start of the background gradient
    _backgroundGradient.addListener(() {
      widget.appBarColor.value = _backgroundGradient.value.colors[0];
    });

    // Color tween for icons.
    _iconColor = ColorTween(begin: Color(0xFF3A3149), end: AppColors.white)
        .animate(_connectAnimController);

    // Update the app bar icon color to match the background
    _iconColor.addListener(() {
      widget.iconColor.value = _iconColor.value;
    });

//    _highlightAnimationController = AnimationController(
//        vsync: this, duration: Duration(milliseconds: 4000));
//    _highlightAnimationController.repeat();
  }

  void _onConnectButtonPressed() {
    // Toggle the current connection state
    switch (_connectionState) {
      case OrchidConnectionState.Disconnecting:
        // Do nothing while we are trying to disconnect
        break;
      case OrchidConnectionState.Invalid:
      case OrchidConnectionState.NotConnected:
        _checkPermissionAndEnableConnection();
        break;
      case OrchidConnectionState.Connecting:
      case OrchidConnectionState.Connected:
        _disableConnection();
        break;
    }
  }

  // duplicates code in monitoring_page
  void _checkPermissionAndEnableConnection() {
    UserPreferences().setDesiredVPNState(true);
    // Get the most recent status, blocking if needed.
    _rxSubscriptions
        .add(OrchidAPI().vpnPermissionStatus.take(1).listen((installed) async {
      debugPrint("vpn: current perm: $installed");
      if (installed) {
        debugPrint("vpn: already installed");
        OrchidAPI().setConnected(true);
        setState(() {});
      } else {
        bool ok = await OrchidAPI().requestVPNPermission();
        if (ok) {
          debugPrint("vpn: user chose to install");
          // Note: It appears that trying to enable the connection too quickly
          // Note: after installing the vpn permission / config fails.
          // Note: Introducing a short artificial delay.
          Future.delayed(Duration(milliseconds: 500)).then((_) {
            OrchidAPI().setConnected(true);
          });
        } else {
          debugPrint("vpn: user skipped");
        }
      }
    }));
  }

  void _disableConnection() {
    UserPreferences().setDesiredVPNState(false);
    OrchidAPI().setConnected(false);
  }

  void _rerouteButtonPressed() {
    OrchidAPI().reroute();
  }

  @override
  void dispose() {
    super.dispose();
    _connectAnimController.dispose();
//    _highlightAnimationController.dispose();
    _rxSubscriptions.forEach((sub) {
      sub.cancel();
    });
  }

  S get s {
    return S.of(context);
  }
}
