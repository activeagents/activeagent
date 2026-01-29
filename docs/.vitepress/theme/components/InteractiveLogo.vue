<template>
  <div class="interactive-logo-container" ref="container">
    <svg
      :width="size"
      :height="size"
      viewBox="0 0 500 500"
      xmlns="http://www.w3.org/2000/svg"
      xmlns:xlink="http://www.w3.org/1999/xlink"
      class="interactive-logo"
    >
      <defs>
        <path d="M421,271.3 C422.733333,265.1 423.666667,244.633333 423.8,209.9 C423.9,173.4 423.8,142.1 423.5,140.4 C423.1,137.9 412.5,126.8 373.1,87.2 C345.6,59.7 321.7,36.3 319.8,35.3 C316.7,33.6 312.5,33.5 250,33.5 C186.5,33.5 183.3,33.6 178.2,35.4 C173.5,37.2 168.3,42.1 125.2,85.3 C69.3,141.4 75.6,134.9 73.7,138.7 C72.3,141.3 72,147.2 71.8,178.6 C71.3,243.6 71.8,276 73.4,276 C74.0666667,276 99.6,304.85435 150,362.563051 L350.015239,362.563051 L421,271.3 Z" id="path-1"></path>
        <filter x="-4.1%" y="-6.1%" width="108.4%" height="146.7%" filterUnits="objectBoundingBox" id="filter-2">
          <feMorphology radius="21" operator="erode" in="SourceAlpha" result="shadowSpreadInner1"></feMorphology>
          <feGaussianBlur stdDeviation="1" in="shadowSpreadInner1" result="shadowBlurInner1"></feGaussianBlur>
          <feOffset dx="0" dy="1" in="shadowBlurInner1" result="shadowOffsetInner1"></feOffset>
          <feComposite in="shadowOffsetInner1" in2="SourceAlpha" operator="arithmetic" k2="-1" k3="1" result="shadowInnerInner1"></feComposite>
          <feColorMatrix values="0 0 0 0 0   0 0 0 0 0   0 0 0 0 0  0 0 0 0.25 0" type="matrix" in="shadowInnerInner1"></feColorMatrix>
        </filter>
        <path d="M346.894815,99.8812603 L335.287136,108.669714 L292.49526,108.669714 L211.805448,108.669714 C194.860905,92.3943898 186.92232,84.2567278 187.989692,84.2567278 C188.990354,84.2567278 187.689494,77.5178389 187.989692,71.1178389 C188.990354,54.5178389 196.99565,38.6178389 211.805448,23.8178389 C219.710677,15.9178389 222.812729,13.5178389 230.117562,10.0178389 C242.025439,4.11783895 250.431,1.81783895 262.839208,1.11783895 C274.146689,0.517838947 285.354103,2.21783895 295.560855,6.01783895 C308.669527,10.9178389 327.481972,26.8178389 335.287136,39.6178389 C342.091637,50.9178389 346.894815,65.8178389 346.894815,76.0178389 C346.894815,82.8178389 346.894815,90.7723127 346.894815,99.8812603 Z" id="path-3"></path>
        <filter x="-16.9%" y="-34.4%" width="133.9%" height="150.2%" filterUnits="objectBoundingBox" id="filter-4">
          <feMorphology radius="6" operator="dilate" in="SourceAlpha" result="shadowSpreadOuter1"></feMorphology>
          <feOffset dx="0" dy="-10" in="shadowSpreadOuter1" result="shadowOffsetOuter1"></feOffset>
          <feGaussianBlur stdDeviation="4" in="shadowOffsetOuter1" result="shadowBlurOuter1"></feGaussianBlur>
          <feComposite in="shadowBlurOuter1" in2="SourceAlpha" operator="out" result="shadowBlurOuter1"></feComposite>
          <feColorMatrix values="0 0 0 0 0   0 0 0 0 0   0 0 0 0 0  0 0 0 0.34 0" type="matrix" in="shadowBlurOuter1"></feColorMatrix>
        </filter>
        <path d="M158.894815,99.8812603 L147.294815,108.669714 L104.531247,108.669714 L23.8948148,108.669714 C6.96148148,92.3943898 -0.971851852,84.2567278 0.0948148148,84.2567278 C1.09481481,84.2567278 -0.205185185,77.5178389 0.0948148148,71.1178389 C1.09481481,54.5178389 9.09481481,38.6178389 23.8948148,23.8178389 C31.7948148,15.9178389 34.8948148,13.5178389 42.1948148,10.0178389 C54.0948148,4.11783895 62.4948148,1.81783895 74.8948148,1.11783895 C86.1948148,0.517838947 97.3948148,2.21783895 107.594815,6.01783895 C120.694815,10.9178389 139.494815,26.8178389 147.294815,39.6178389 C154.094815,50.9178389 158.894815,65.8178389 158.894815,76.0178389 C158.894815,82.8178389 158.894815,90.7723127 158.894815,99.8812603 Z" id="path-5"></path>
        <filter x="-17.0%" y="-34.4%" width="134.0%" height="150.2%" filterUnits="objectBoundingBox" id="filter-6">
          <feMorphology radius="6" operator="dilate" in="SourceAlpha" result="shadowSpreadOuter1"></feMorphology>
          <feOffset dx="0" dy="-10" in="shadowSpreadOuter1" result="shadowOffsetOuter1"></feOffset>
          <feGaussianBlur stdDeviation="4" in="shadowOffsetOuter1" result="shadowBlurOuter1"></feGaussianBlur>
          <feComposite in="shadowBlurOuter1" in2="SourceAlpha" operator="out" result="shadowBlurOuter1"></feComposite>
          <feColorMatrix values="0 0 0 0 0   0 0 0 0 0   0 0 0 0 0  0 0 0 0.34 0" type="matrix" in="shadowBlurOuter1"></feColorMatrix>
        </filter>
        <path d="M187.894815,73.4178389 C187.894815,60.8178389 195.094815,43.4178389 205.494815,30.8178389 C213.379338,21.2587265 220.290164,15.3509792 230.065863,10.614813 C233.275023,8.66038782 236.386019,7.08045632 239.228774,6.01783895 C246.891881,3.1648446 255.119044,1.49558371 263.529125,1.09469751 C267.0628,0.85875903 270.579909,0.91174645 274.130563,1.26068041 C285.374227,2.10514099 293.474739,4.46989454 304.672068,10.0178389 C311.734427,13.4016614 314.868385,15.7572978 322.212521,23.0490899 C322.404693,23.2351845 322.598616,23.4248565 322.794815,23.6178389 C326.305926,27.0845056 329.397284,30.5857402 332.082058,34.1500749 L332.147549,34.2348166 C341.115704,45.9935786 346.030197,58.3486082 346.799937,71.1178389 C346.957028,74.4668935 346.675697,77.9087466 346.51516,80.4291984 C346.692971,80.6455419 346.91685,80.7012283 347.194815,80.6178389 C347.366243,80.5416485 348.038982,80.5008321 349.213031,80.49539 L349.775191,80.4953287 C352.88763,80.5074784 358.768553,80.7149818 367.417962,81.1178389 C374.646021,86.4691871 378.26005,91.7025204 378.26005,96.8178389 C378.26005,101.933158 374.646021,107.042446 367.417962,112.145703 L15.4033015,112.145703 L-20.3804397,113.34828 C-27.8069326,110.321555 -31.520179,105.628751 -31.520179,99.2698651 C-31.520179,92.9109798 -27.8069326,88.0871504 -20.3804397,84.798377 C-13.630058,84.6046663 -8.53680689,84.4629134 -5.10068646,84.3731182 C-5.11478339,84.2955415 -5.08402304,84.2567278 -5.0103076,84.2567278 C-4.00964562,84.2567278 -5.3105062,77.5178389 -5.0103076,71.1178389 C-4.00964562,54.5178389 3.99565021,38.6178389 18.8054475,23.8178389 C26.7106772,15.9178389 29.8127293,13.5178389 37.1175618,10.0178389 C49.0254393,4.11783895 57.4309999,1.81783895 69.8392085,1.11783895 C72.1663903,0.994353514 74.4893337,0.968290025 76.8001874,1.03790497 C76.1654979,1.05762673 75.5303145,1.0840956 74.8948148,1.11783895 C62.4948148,1.81783895 54.0948148,4.11783895 42.1948148,10.0178389 C34.8948148,13.5178389 31.7948148,15.9178389 23.8948148,23.8178389 C9.09481481,38.6178389 1.09481481,54.5178389 0.0948148148,71.1178389 C-0.205185185,77.5178389 1.09481481,84.2567278 0.0948148148,84.2567278 C-0.399641779,84.2567278 -2.13147554,84.2955246 -5.10068646,84.3731182 C-4.93820825,85.419556 3.03113715,93.5184043 18.8054475,108.669714 L142.287136,108.669714 L153.894815,99.8812603 L153.894815,76.0178389 C153.894815,65.8178389 149.091637,50.9178389 142.287136,39.6178389 C134.481972,26.8178389 115.669527,10.9178389 102.560855,6.01783895 C94.4547451,2.99991335 85.7174781,1.3065402 76.8001874,1.03790497 C87.4514036,0.715693159 97.9684517,2.43154681 107.594815,6.01783895 C120.694815,10.9178389 139.494815,26.8178389 147.294815,39.6178389 C154.094815,50.9178389 158.894815,65.8178389 158.894815,76.0178389 L158.894815,80.4178389 L164.994815,80.4178389 C168.394815,80.1178389 174.994815,79.8178389 179.494815,79.8178389 L187.894815,79.8178389 L187.894815,99.8812603 L199.502494,108.669714 L322.984182,108.669714 C339.928725,92.3943898 347.86731,84.2567278 346.799937,84.2567278 C346.322911,84.2567278 346.368913,82.7252975 346.51516,80.4291984 C346.051215,79.8676047 345.894815,78.2225908 345.894815,75.1178389 C345.894815,59.8733945 341.478765,46.6252464 332.082058,34.1500749 L331.695764,33.6473763 C329.11651,30.3213728 326.211958,27.04348 322.984182,23.8178389 C322.721779,23.5556097 322.464669,23.2994405 322.212521,23.0490899 C316.441041,17.4371013 312.579318,14.7084822 306.094815,11.4178389 C294.424234,5.5825487 284.144,2.24473248 274.130563,1.26068041 C273.416976,1.20707446 272.690824,1.15960825 271.950421,1.11783895 C269.132461,0.968311739 266.320716,0.961629774 263.529125,1.09469751 C257.388618,1.50637371 251.198126,2.79175657 244.694815,4.91783895 C239.07288,6.73136632 234.300573,8.56316526 230.065863,10.614813 C218.478399,17.6682203 205.615024,29.5936557 199.502494,39.6178389 C192.698213,50.9174732 187.895126,65.8168744 187.894815,76.0168484 L187.894815,73.4178389 Z" id="path-7"></path>
        <filter x="-6.6%" y="-32.9%" width="113.2%" height="148.0%" filterUnits="objectBoundingBox" id="filter-8">
          <feMorphology radius="6" operator="dilate" in="SourceAlpha" result="shadowSpreadOuter1"></feMorphology>
          <feOffset dx="0" dy="-10" in="shadowSpreadOuter1" result="shadowOffsetOuter1"></feOffset>
          <feGaussianBlur stdDeviation="4" in="shadowOffsetOuter1" result="shadowBlurOuter1"></feGaussianBlur>
          <feComposite in="shadowBlurOuter1" in2="SourceAlpha" operator="out" result="shadowBlurOuter1"></feComposite>
          <feColorMatrix values="0 0 0 0 0   0 0 0 0 0   0 0 0 0 0  0 0 0 0.34 0" type="matrix" in="shadowBlurOuter1"></feColorMatrix>
        </filter>
      </defs>

      <g id="ActiveAgent" stroke="none" fill="none" fill-rule="evenodd" stroke-width="1">
        <g id="Pieces" transform="translate(25, 475) scale(-1, 1) rotate(-180) translate(-25, -475)translate(-0, 450)">
          <!-- Face -->
          <g id="Face" fill-rule="nonzero">
            <use fill="#EB5555" xlink:href="#path-1"></use>
            <use fill="black" fill-opacity="1" filter="url(#filter-2)" xlink:href="#path-1"></use>
            <use :stroke="strokeColor" stroke-width="12" xlink:href="#path-1"></use>
          </g>

          <!-- Mouth -->
          <path d="M216.5,202.5 C213.4,199.5 213.4,198.7 216.5,193.4 C223.2,182 248.2,176 264.5,181.9 C273,185 280.3,190.1 282.4,194.5 C284,197.9 284,198.3 282.5,200.6 C281.6,202 279.8,203.6 278.5,204.2 C276.4,205.1 275.4,204.7 270.1,200.8 C263,195.4 254.7,193.3 244.4,194.4 C236.1,195.3 234.3,196 228.6,200.9 C223.1,205.6 220,206.1 216.5,202.5 Z" id="Mouth" :fill="mouthColor" fill-rule="nonzero"></path>

          <!-- Hat -->
          <path d="M177.8,484.5 C169.1,482.1 162,475.2 157.7,465 C156.2,461.4 151.9,446.6 148.1,432 C144.3,417.4 140.7,404.3 140.1,402.8 L139,400 L94.8,400 C70.4,400 49.5,399.7 48.2,399.4 C45.1,398.5 42.7,393.8 43.9,390.8 C45.1,387.9 49.4,383.3 54,379.9 C68.7,369.2 86.3,364.8 120,363.4 C126.066667,363.2 134.064888,362.921017 143.994663,362.563051 C289.598221,363.25435 367.433333,363.766667 377.5,364.1 C411,365.2 433.1,371.5 446.2,383.8 C453.8,390.9 455.1,394.7 451.3,399 C451,399.3 429.6,399.7 403.7,400 L356.6,400.5 L353.3,412.5 C351.5,419.1 348.2,431.3 346.1,439.5 C339.9,463 336.7,470.5 329.4,477.5 C322.9,483.8 315.7,486.3 305.5,485.8 C298.1,485.4 296.1,484.7 280.5,477.8 C271.2,473.7 261.7,469.7 259.5,468.9 C250.9,466.1 238.1,467.9 224.9,473.8 C197.3,486.1 189.8,487.8 177.8,484.5 Z" id="Hat" :stroke="hatStrokeColor" stroke-width="11" :fill="hatFillColor" fill-rule="nonzero"></path>

          <!-- Eyes (behind lenses - only visible in dark mode through transparent lenses) -->
          <g v-if="isDark" id="Eyes" transform="translate(75.1052, 196.1822)">
            <!-- Left eye - eyeball -->
            <ellipse fill="#F5E6D3" cx="87" cy="55" rx="35" ry="29"></ellipse>
            <!-- Left eye - iris (animated) -->
            <ellipse fill="#5D4037" :cx="leftIris.x" :cy="leftIris.y" rx="20" ry="20"></ellipse>
            <!-- Left eye - pupil (animated) -->
            <ellipse fill="#2D1F1F" :cx="leftPupil.x" :cy="leftPupil.y" rx="12" ry="12"></ellipse>
            <!-- Left eye - highlight -->
            <ellipse fill="#FFFFFF" :cx="leftHighlight.x" :cy="leftHighlight.y" rx="5" ry="5"></ellipse>

            <!-- Right eye - eyeball -->
            <ellipse fill="#F5E6D3" cx="259" cy="55" rx="35" ry="29"></ellipse>
            <!-- Right eye - iris (animated) -->
            <ellipse fill="#5D4037" :cx="rightIris.x" :cy="rightIris.y" rx="20" ry="20"></ellipse>
            <!-- Right eye - pupil (animated) -->
            <ellipse fill="#2D1F1F" :cx="rightPupil.x" :cy="rightPupil.y" rx="12" ry="12"></ellipse>
            <!-- Right eye - highlight -->
            <ellipse fill="#FFFFFF" :cx="rightHighlight.x" :cy="rightHighlight.y" rx="5" ry="5"></ellipse>
          </g>

          <!-- Lenses -->
          <g id="Lenses" transform="translate(75.1052, 196.1822)" fill-rule="nonzero">
            <g id="right-lens" transform="translate(267.3948, 54.8349) scale(-1, 1) translate(-267.3948, -54.8349)">
              <use fill="black" fill-opacity="1" filter="url(#filter-4)" xlink:href="#path-3"></use>
              <use :stroke="lensStrokeColor" stroke-width="8" :fill-opacity="lensFillOpacity" :fill="lensFillColor" xlink:href="#path-3"></use>
            </g>
            <g id="left-lens">
              <use fill="black" fill-opacity="1" filter="url(#filter-6)" xlink:href="#path-5"></use>
              <use :stroke="lensStrokeColor" stroke-width="8" :fill-opacity="lensFillOpacity" :fill="lensFillColor" xlink:href="#path-5"></use>
            </g>
          </g>

          <!-- Frames -->
          <g id="Frames" transform="translate(75.1052, 196.1822)" fill-rule="nonzero">
            <g id="Combined-Shape">
              <use fill="black" fill-opacity="1" filter="url(#filter-8)" xlink:href="#path-7"></use>
              <use :stroke="frameStrokeColor" stroke-width="8" :fill="frameFillColor" xlink:href="#path-7"></use>
            </g>
          </g>

          <!-- Sparkles -->
          <g id="Sparkles" transform="translate(83.563, 252.2116)" fill="#FFFFFF" fill-rule="nonzero">
            <path d="M12.8369719,35.2884482 C13.1369719,33.9884482 14.4369719,31.8884482 15.6369719,30.7884482 L17.8369719,28.7884482 L15.6369719,26.7884482 C14.4369719,25.6884482 13.1369719,23.5884482 12.8369719,22.2884482 C12.0369719,19.0884482 10.6369719,19.0884482 9.4369719,22.1884482 C8.9369719,23.4884482 7.5369719,25.5884482 6.2369719,26.7884482 C4.0369719,28.7884482 4.0369719,28.9884482 5.7369719,29.9884482 C6.8369719,30.4884482 8.2369719,32.4884482 9.0369719,34.3884482 C10.7369719,38.3884482 11.9369719,38.6884482 12.8369719,35.2884482 Z M29.2369719,33.0884482 C30.1369719,29.6884482 31.8369719,27.0884482 34.9369719,24.0884482 L39.3369719,19.8884482 L36.3369719,17.7884482 C33.4369719,15.5884482 28.4369719,7.28844821 28.4369719,4.28844821 C28.4369719,2.18844821 26.5369719,2.38844821 25.8369719,4.58844821 C23.9369719,10.3884482 21.6369719,14.3884482 18.3369719,17.1884482 L14.5369719,20.3884482 L17.3369719,22.0884482 C19.8369719,23.5884482 24.3369719,30.9884482 25.8369719,36.0884482 C26.7369719,39.0884482 27.9369719,37.9884482 29.2369719,33.0884482 Z M10.9369719,12.4884482 L13.0369719,9.28844821 L10.9369719,6.08844821 C8.8369719,2.78844821 7.4369719,1.88844821 7.4369719,3.98844821 C7.4369719,4.58844821 6.5369719,6.08844821 5.4369719,7.28844821 L3.4369719,9.48844821 L5.4369719,11.2884482 C6.5369719,12.2884482 7.4369719,13.6884482 7.4369719,14.4884482 C7.4369719,16.6884482 8.8369719,15.8884482 10.9369719,12.4884482 Z" id="Shape"></path>
            <path d="M203.436972,36.3884482 C203.436972,35.5884482 204.636972,33.5884482 206.036972,31.8884482 L208.636972,28.7884482 L206.036972,25.6884482 C204.636972,23.9884482 203.436972,21.9884482 203.436972,21.1884482 C203.436972,18.5884482 201.436972,19.7884482 200.036972,23.1884482 C199.236972,25.0884482 197.836972,27.0884482 196.736972,27.6884482 C195.036972,28.6884482 195.036972,28.7884482 197.036972,30.1884482 C198.236972,30.9884482 199.736972,33.0884482 200.436972,34.7884482 C201.736972,37.8884482 203.436972,38.7884482 203.436972,36.3884482 Z M220.836972,32.5884482 C221.936972,29.2884482 224.236972,25.7884482 226.736972,23.3884482 C229.736972,20.4884482 230.536972,19.2884482 229.436972,18.9884482 C226.636972,17.9884482 222.436972,12.5884482 220.736972,7.68844821 C219.736972,4.98844821 218.736972,2.78844821 218.336972,2.78844821 C218.036972,2.78844821 216.736972,5.28844821 215.536972,8.28844821 C214.336972,11.2884482 211.736972,15.0884482 209.836972,16.6884482 C205.936972,20.1884482 205.636972,21.3884482 208.436972,22.2884482 C210.936972,23.0884482 214.736972,28.7884482 216.436972,34.0884482 C217.036972,36.0884482 217.936972,37.7884482 218.236972,37.7884482 C218.636972,37.7884482 219.836972,35.3884482 220.836972,32.5884482 Z M201.136972,14.0884482 C201.436972,13.0884482 202.436972,11.4884482 203.336972,10.4884482 C204.336972,9.28844821 204.536972,8.38844821 203.836972,7.98844821 C203.236972,7.58844821 202.236972,6.28844821 201.536972,5.08844821 C200.136972,2.38844821 198.836972,2.18844821 198.036972,4.58844821 C197.736972,5.48844821 196.936972,6.98844821 196.336972,7.88844821 C195.336972,9.28844821 195.436972,9.88844821 196.736972,11.2884482 C197.636972,12.1884482 198.436972,13.5884482 198.436972,14.3884482 C198.436972,16.3884482 200.336972,16.1884482 201.136972,14.0884482 Z" id="Shape"></path>
            <path d="M9.1369719,31.0884482 C7.3369719,28.8884482 7.4369719,28.6884482 9.2369719,26.2884482 L11.2369719,23.7884482 L12.8369719,26.2884482 C14.4369719,28.6884482 14.4369719,28.9884482 12.7369719,31.1884482 L10.9369719,33.4884482 L9.1369719,31.0884482 Z" id="Path"></path>
            <path d="M25.6369719,29.9884482 C25.1369719,28.3884482 23.2369719,25.4884482 21.5369719,23.5884482 L18.4369719,20.0884482 L20.5369719,18.1884482 C21.7369719,17.0884482 23.6369719,14.2884482 24.8369719,11.8884482 L27.1369719,7.48844821 L29.4369719,12.1884482 C30.6369719,14.7884482 32.7369719,17.5884482 34.0369719,18.4884482 C36.5369719,20.0884482 36.5369719,20.0884482 34.4369719,21.4884482 C33.3369719,22.2884482 31.1369719,25.1884482 29.5369719,27.8884482 L26.6369719,32.8884482 L25.6369719,29.9884482 Z" id="Shape"></path>
            <path d="M216.636972,29.4884482 C215.936972,27.6884482 214.136972,24.8884482 212.436972,23.2884482 L209.436972,20.3884482 L211.936972,17.7884482 C213.236972,16.3884482 215.236972,13.4884482 216.336972,11.2884482 L218.236972,7.38844821 L219.936972,10.8884482 C220.836972,12.7884482 222.936972,15.6884482 224.636972,17.3884482 L227.536972,20.4884482 L225.136972,22.0884482 C223.836972,22.8884482 221.736972,25.6884482 220.536972,28.1884482 C219.436972,30.6884482 218.336972,32.7884482 218.136972,32.7884482 C217.936972,32.7884482 217.336972,31.2884482 216.636972,29.4884482 Z" id="Shape"></path>
          </g>
        </g>
      </g>
    </svg>
  </div>
</template>

<script setup lang="ts">
import { ref, reactive, onMounted, onUnmounted, computed } from 'vue'
import { useData } from 'vitepress'

const props = defineProps<{
  size?: number
}>()

const { isDark } = useData()
const size = computed(() => props.size || 320)
const container = ref<HTMLElement>()

// Theme-dependent colors
const strokeColor = computed(() => isDark.value ? '#3D2222' : '#000000')
const mouthColor = computed(() => isDark.value ? '#3D2222' : '#000000')
const hatStrokeColor = computed(() => isDark.value ? '#2D1515' : '#000000')
const hatFillColor = computed(() => isDark.value ? '#2D1515' : '#000000')
const lensStrokeColor = computed(() => isDark.value ? '#2D1515' : '#000000')
const lensFillColor = computed(() => isDark.value ? '#EB5555' : '#000000')
const lensFillOpacity = computed(() => isDark.value ? 0.35 : 0.8)
const frameStrokeColor = computed(() => isDark.value ? '#2D1515' : '#000000')
const frameFillColor = computed(() => isDark.value ? '#2D1515' : '#000000')

// Eye centers in the transformed coordinate space (relative to Eyes group)
const LEFT_EYE_CENTER = { x: 87, y: 55 }
const RIGHT_EYE_CENTER = { x: 259, y: 55 }
const MAX_EYE_OFFSET = 12 // How far iris/pupil can move from center

// Eye positions (reactive) - iris, pupil, and highlight move together
const leftIris = reactive({ x: LEFT_EYE_CENTER.x, y: LEFT_EYE_CENTER.y + 2 })
const leftPupil = reactive({ x: LEFT_EYE_CENTER.x, y: LEFT_EYE_CENTER.y + 2 })
const leftHighlight = reactive({ x: LEFT_EYE_CENTER.x - 7, y: LEFT_EYE_CENTER.y - 4 })

const rightIris = reactive({ x: RIGHT_EYE_CENTER.x, y: RIGHT_EYE_CENTER.y + 2 })
const rightPupil = reactive({ x: RIGHT_EYE_CENTER.x, y: RIGHT_EYE_CENTER.y + 2 })
const rightHighlight = reactive({ x: RIGHT_EYE_CENTER.x - 7, y: RIGHT_EYE_CENTER.y - 4 })

// Physics state for googly eyes
const leftVelocity = reactive({ x: 0, y: 0 })
const rightVelocity = reactive({ x: 0, y: 0 })

// Shake detection
const velocityHistory: { vx: number; vy: number; time: number }[] = []
let isGoogly = false
let googlyDecayTimeout: number | null = null
let animationFrame: number

// Mouse tracking
let lastMouseX = 0
let lastMouseY = 0
let lastTime = Date.now()

const detectShake = () => {
  const now = Date.now()
  while (velocityHistory.length > 0 && now - velocityHistory[0].time > 300) {
    velocityHistory.shift()
  }

  if (velocityHistory.length < 4) return false

  let directionChanges = 0
  for (let i = 1; i < velocityHistory.length; i++) {
    const prev = velocityHistory[i - 1]
    const curr = velocityHistory[i]
    if ((prev.vx > 50 && curr.vx < -50) || (prev.vx < -50 && curr.vx > 50) ||
        (prev.vy > 50 && curr.vy < -50) || (prev.vy < -50 && curr.vy > 50)) {
      directionChanges++
    }
  }

  return directionChanges >= 3
}

const triggerGoogly = () => {
  isGoogly = true

  const randomForce = () => (Math.random() - 0.5) * 12
  leftVelocity.x += randomForce()
  leftVelocity.y += randomForce()
  rightVelocity.x += randomForce()
  rightVelocity.y += randomForce()

  if (googlyDecayTimeout) {
    clearTimeout(googlyDecayTimeout)
  }

  googlyDecayTimeout = window.setTimeout(() => {
    isGoogly = false
  }, 800)
}

const handleMouseMove = (e: MouseEvent) => {
  const now = Date.now()
  const dt = Math.max(1, now - lastTime)

  const vx = ((e.clientX - lastMouseX) / dt) * 100
  const vy = ((e.clientY - lastMouseY) / dt) * 100

  velocityHistory.push({ vx, vy, time: now })

  if (detectShake()) {
    triggerGoogly()
  }

  lastMouseX = e.clientX
  lastMouseY = e.clientY
  lastTime = now
}

const updateEyes = () => {
  if (!container.value || !isDark.value) {
    animationFrame = requestAnimationFrame(updateEyes)
    return
  }

  const rect = container.value.getBoundingClientRect()
  const svgCenterX = rect.left + rect.width / 2
  const svgCenterY = rect.top + rect.height / 2

  const dx = lastMouseX - svgCenterX
  const dy = lastMouseY - svgCenterY
  const distance = Math.sqrt(dx * dx + dy * dy)
  const maxDistance = 500

  const normalizedDist = Math.min(distance / maxDistance, 1)
  const offsetX = (dx / Math.max(distance, 1)) * MAX_EYE_OFFSET * normalizedDist
  const offsetY = (dy / Math.max(distance, 1)) * MAX_EYE_OFFSET * normalizedDist

  // Target positions for iris/pupil (base + 2 for y offset in original SVG)
  const leftTargetX = LEFT_EYE_CENTER.x + offsetX
  const leftTargetY = LEFT_EYE_CENTER.y + 2 + offsetY
  const rightTargetX = RIGHT_EYE_CENTER.x + offsetX
  const rightTargetY = RIGHT_EYE_CENTER.y + 2 + offsetY

  if (isGoogly) {
    const spring = 0.08
    const damping = 0.85
    const gravity = 0.25

    leftVelocity.x += (leftTargetX - leftIris.x) * spring
    leftVelocity.y += (leftTargetY - leftIris.y) * spring + gravity
    rightVelocity.x += (rightTargetX - rightIris.x) * spring
    rightVelocity.y += (rightTargetY - rightIris.y) * spring + gravity

    leftVelocity.x *= damping
    leftVelocity.y *= damping
    rightVelocity.x *= damping
    rightVelocity.y *= damping

    leftIris.x += leftVelocity.x
    leftIris.y += leftVelocity.y
    rightIris.x += rightVelocity.x
    rightIris.y += rightVelocity.y

    // Bounce off boundaries
    const bounce = (pos: { x: number; y: number }, vel: { x: number; y: number }, center: { x: number; y: number }, baseY: number) => {
      const maxX = center.x + MAX_EYE_OFFSET
      const minX = center.x - MAX_EYE_OFFSET
      const maxY = baseY + MAX_EYE_OFFSET
      const minY = baseY - MAX_EYE_OFFSET

      if (pos.x > maxX) { pos.x = maxX; vel.x *= -0.6 }
      if (pos.x < minX) { pos.x = minX; vel.x *= -0.6 }
      if (pos.y > maxY) { pos.y = maxY; vel.y *= -0.6 }
      if (pos.y < minY) { pos.y = minY; vel.y *= -0.6 }
    }

    bounce(leftIris, leftVelocity, LEFT_EYE_CENTER, LEFT_EYE_CENTER.y + 2)
    bounce(rightIris, rightVelocity, RIGHT_EYE_CENTER, RIGHT_EYE_CENTER.y + 2)
  } else {
    const lerp = 0.15
    leftIris.x += (leftTargetX - leftIris.x) * lerp
    leftIris.y += (leftTargetY - leftIris.y) * lerp
    rightIris.x += (rightTargetX - rightIris.x) * lerp
    rightIris.y += (rightTargetY - rightIris.y) * lerp

    leftVelocity.x *= 0.9
    leftVelocity.y *= 0.9
    rightVelocity.x *= 0.9
    rightVelocity.y *= 0.9
  }

  // Sync pupil and highlight with iris
  leftPupil.x = leftIris.x
  leftPupil.y = leftIris.y
  leftHighlight.x = leftIris.x - 7
  leftHighlight.y = leftIris.y - 6

  rightPupil.x = rightIris.x
  rightPupil.y = rightIris.y
  rightHighlight.x = rightIris.x - 7
  rightHighlight.y = rightIris.y - 6

  animationFrame = requestAnimationFrame(updateEyes)
}

onMounted(() => {
  lastMouseX = window.innerWidth / 2
  lastMouseY = window.innerHeight / 2

  window.addEventListener('mousemove', handleMouseMove)

  window.addEventListener('touchmove', (e) => {
    if (e.touches.length > 0) {
      const touch = e.touches[0]
      handleMouseMove({ clientX: touch.clientX, clientY: touch.clientY } as MouseEvent)
    }
  })

  updateEyes()
})

onUnmounted(() => {
  window.removeEventListener('mousemove', handleMouseMove)
  if (animationFrame) {
    cancelAnimationFrame(animationFrame)
  }
  if (googlyDecayTimeout) {
    clearTimeout(googlyDecayTimeout)
  }
})
</script>

<style scoped>
.interactive-logo-container {
  display: flex;
  align-items: center;
  justify-content: center;
}

.interactive-logo {
  cursor: pointer;
}
</style>
