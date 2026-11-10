package android.telephony;
import java.util.List;
public class TelephonyManager {
    public abstract static class CellInfoCallback {
        public CellInfoCallback() {}
        public abstract void onCellInfo(List cells);
        public void onError(int code, Throwable error) {}
    }
}
