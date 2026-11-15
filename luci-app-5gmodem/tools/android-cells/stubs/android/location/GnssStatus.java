package android.location;
public class GnssStatus {
    public abstract static class Callback {
        public Callback() {}
        public void onStarted() {}
        public void onStopped() {}
        public void onFirstFix(int ttffMillis) {}
        public void onSatelliteStatusChanged(GnssStatus status) {}
    }
}
