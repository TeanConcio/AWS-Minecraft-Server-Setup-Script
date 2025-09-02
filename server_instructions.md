# Server Instructions

---

## Setting Up the Minecraft Client

1. **Download, Install, and Open the CurseForge App**  
   [Download CurseForge](https://download.overwolf.com/install/Download?ExtensionId=cfiahnpaolfnlgaihhmobmnjdafknjnjdpdabpcm&utm_term=eyJkb21haW4iOiJjZi13ZWIifQ%3D%3D)

2. **Set Up Minecraft Folder**  
   - Select the **Minecraft** game.
   - Click **Set Up Folder**.

3. **Install the Modpack**  
   - Use the search bar to find:  
     **Prominence II: Hasturian Era** by *ElocinDev*  
   - Click **Install**.

4. **Adjust Memory Settings**  
   - While the modpack downloads, click **Settings** (bottom left).
   - Select **Minecraft**, scroll to **Java Settings**.
   - Set **Allocated Memory** to at least **8GB (8192 MB)**.

5. **Launch the Modpack**  
   - Once installed, hover over the modpack and click **Play**.

6. **Start Minecraft**  
   - The Minecraft Launcher will open.
   - Accept any disclaimers and press **Play**.

7. **Join the Server**  
   - Go to **Multiplayer**.
   - Add the server using the IP address (see **Opening the Server**).
   - Click **Join Server**.

---

## Opening the Server

1. **Access AWS Console**  
   [AWS EC2 Console – ap-southeast-5](https://ap-southeast-5.console.aws.amazon.com/ec2/home?region=ap-southeast-5#Instances:)

2. **Log In with provided IAM User Credentials**  

3. **Start the Server Instance**  
   - In the **EC2 Instances** page, select the Minecraft server.
   - Right-click and choose **Start Instance**.  
   *(Skip this step if the server is already running.)*

4. **Get the Server IP Address**  
   - Copy the **Public IPv4 address** once the server starts.

5. **Connect via Minecraft Client**  
   - Launch Minecraft with the correct modpack.
   - Go to **Multiplayer**, add the server using the IP address.
   - Click **Join**.

6. **Shut Down the Server After Use**  
   - The server auto-shuts down ~5 minutes after all players leave.
   - To confirm, check the **Instance State** in EC2.  
     It should say **Stopped**.  
   - If not, manually stop the instance to avoid extra charges.

---

## Changing Server Resources (and Saving Money)

1. **Adjust Based on Player Count**  
   - Recommended specs:  
     - **8 GB RAM** → Up to 4 players  
     - **16 GB RAM** → More than 4 players

2. **Change Instance Type**  
   - Follow steps 1–3 from **Opening the Server** except starting the server.
   - Ensure the server is **stopped**.
   - Right-click and select **Instance Settings** → **Change Instance Type**.  
     *(Coordinate with players if the server is running.)*

3. **Select New Instance Type**  
   - Current type will be displayed.
   - Choose based on player count:  
     - `c7g.xlarge` → 8 GB RAM  
     - `c7g.2xlarge` → 16 GB RAM

4. **Apply Changes**  
   - Review the **Instance Type Comparison**.
   - Scroll down and click **Change Instance Type**.
   - Once done, proceed with **Opening the Server** as usual.

---

*For any questions, please contact the System Admin.*

---
