import java.awt.image.BufferedImage;
import java.io.File;
import java.util.ArrayList;
import java.util.List;
import javax.imageio.ImageIO;

/** Appends PNG tiles left to right, writes the result, and prints the dark bar runs along the middle row. */
public class Stitch {
    public static void main(String[] args) throws Exception {
        File out = new File(args[0]);
        List<BufferedImage> tiles = new ArrayList<>();
        int width = 0, height = 0;
        for (int i = 1; i < args.length; i++) {
            BufferedImage tile = ImageIO.read(new File(args[i]));
            tiles.add(tile);
            width += tile.getWidth();
            height = Math.max(height, tile.getHeight());
        }
        BufferedImage stitched = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        int x = 0;
        for (BufferedImage tile : tiles) {
            stitched.getGraphics().drawImage(tile, x, 0, null);
            x += tile.getWidth();
        }
        ImageIO.write(stitched, "png", out);

        int y = height / 2;
        StringBuilder runs = new StringBuilder();
        int runStart = -1;
        for (int i = 0; i <= width; i++) {
            boolean dark = i < width && (stitched.getRGB(i, y) >>> 24) > 128 && (stitched.getRGB(i, y) & 0xff) < 128;
            if (dark && runStart < 0) runStart = i;
            if (!dark && runStart >= 0) {
                runs.append(String.format(" [%d..%d]=%d", runStart, i - 1, i - runStart));
                runStart = -1;
            }
        }
        int seam = tiles.get(0).getWidth();
        System.out.printf("%s (%dx%d, tile seam at x=%d): bar runs on row %d:%s%n", out.getName(), width, height, seam, y, runs);
    }
}
