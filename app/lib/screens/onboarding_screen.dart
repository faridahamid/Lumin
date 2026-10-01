import 'package:flutter/material.dart';
import 'package:lumin/screens/setup.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background image
          Positioned.fill(
            child: Image.asset(
              'assets/images/Lumin_mobile_412x914.png',
              fit: BoxFit.cover,
            ),
          ),

          // Dark overlay
          // Positioned.fill(
          //   child: Container(color: Colors.black.withOpacity(0.6)),
          // ),

          // Content
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Push content DOWN
                  const Spacer(flex: 16),

                  // Text block (now lower)
                  const Text(
                    "Lumin is a voice-powered mobile assistant that helps visually impaired users recognize objects and read text aloud.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.4,
                      color: Color.fromARGB(179, 224, 226, 237),
                    ),
                  ),

                  const Spacer(flex: 2),

                  // Get Started button
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color.fromARGB(255, 2, 42, 77),
                      minimumSize: const Size(double.infinity, 56),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 8,
                    ),
                    onPressed: () {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(builder: (_) => const SetupScreen()),
                      );
                    },
                    child: const Text(
                      "Get Started",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
