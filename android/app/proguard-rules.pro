-dontwarn java.beans.ConstructorProperties
-dontwarn java.beans.Transient
-dontwarn org.slf4j.impl.StaticLoggerBinder
-dontwarn org.slf4j.impl.StaticMDCBinder

# Stripe Terminal SDK (Tap to Pay)
-keep class com.stripe.stripeterminal.** { *; }
-keep class com.stripe.stripeterminal.external.** { *; }
-keep class com.stripe.stripeterminal.taptopay.** { *; }
-dontwarn com.stripe.stripeterminal.**
-dontwarn com.stripe.stripeterminal.taptopay.**
