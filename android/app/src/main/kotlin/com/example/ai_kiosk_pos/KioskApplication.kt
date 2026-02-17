package com.example.ai_kiosk_pos

import android.app.Application
import com.stripe.stripeterminal.TerminalApplicationDelegate

class KioskApplication : Application() {
  override fun onCreate() {
    super.onCreate()
    TerminalApplicationDelegate.onCreate(this)
  }
}
